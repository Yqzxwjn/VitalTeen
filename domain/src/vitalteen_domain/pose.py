"""姿态帧对象 —— 坐标系铁律的强制执行点。

设计意图：让「拿归一化坐标直接算角度」这个经典 bug **在类型层面写不出来**。

归一化坐标只能通过 :meth:`PoseFrame.pixel` / :meth:`PoseFrame.pixel_mid` 转成
像素坐标后才能喂给 :mod:`vitalteen_domain.geometry` 的算子。没有别的方法能拿到
可用于计算的点 —— 这就是 docs/domain-layer-design.md §1.2 约束 A 的实现方式。

世界坐标（MediaPipe 独有）原点在双髋中点、单位为米。它给的是**相对人体的量**，
可以回答「髋下蹲到膝以下了吗」，**不能**回答「跳了几厘米」。且其 z 轴精度显著
低于 x/y，不得作为主要特征。
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from .geometry import Point, angle3
from .landmarks import N_LANDMARKS, L


class PoseFrameError(ValueError):
    """姿态帧数据不合法。"""


@dataclass(frozen=True, slots=True)
class Landmark:
    """单个关键点。

    Attributes:
        x, y: 归一化坐标，取值 [0, 1]，**允许越界**（人出画时可能 <0 或 >1）。
        z: 深度。归一化坐标系下其尺度与 x 近似、原点在两髋中点；世界坐标系下单位为米。
        visibility: 可见性/置信度，[0, 1]。ML Kit 使用 ``InFrameLikelihood`` 语义。
    """

    x: float
    y: float
    z: float = 0.0
    visibility: float = 1.0


@dataclass(frozen=True, slots=True)
class PoseFrame:
    """一帧姿态数据。

    Args:
        landmarks: 33 个归一化关键点。
        world_landmarks: 33 个米制世界坐标点；ML Kit 后端为 ``None``。
        frame_width, frame_height: 采集分辨率（像素）。**必须由相机层传入**，
            不得在本层猜测或写死 —— 它是归一化坐标还原的唯一依据。
        timestamp_ms: 采集时间戳（毫秒，单调递增）。
    """

    landmarks: tuple[Landmark, ...]
    frame_width: int
    frame_height: int
    timestamp_ms: int
    world_landmarks: tuple[Landmark, ...] | None = None

    def __post_init__(self) -> None:
        if len(self.landmarks) != N_LANDMARKS:
            raise PoseFrameError(
                f"landmarks 必须是 {N_LANDMARKS} 个，收到 {len(self.landmarks)} 个"
            )
        if self.world_landmarks is not None and len(self.world_landmarks) != N_LANDMARKS:
            raise PoseFrameError(
                f"world_landmarks 必须是 {N_LANDMARKS} 个，收到 {len(self.world_landmarks)} 个"
            )
        if self.frame_width <= 0 or self.frame_height <= 0:
            raise PoseFrameError("frame_width / frame_height 必须为正数")

    # ---- 归一化坐标（仅供显示与几何换算，不直接用于角度计算）----

    def pixel(self, idx: L) -> Point:
        """把关键点还原为像素坐标。

        这是通往 :mod:`vitalteen_domain.geometry` 的**唯一入口**。
        不做可见性检查 —— 可见性阈值是配置项而非帧的属性，
        调用方应先用 :meth:`is_visible` / :meth:`all_visible` 判断。
        """
        lm = self.landmarks[idx]
        return (lm.x * self.frame_width, lm.y * self.frame_height)

    def pixel_mid(self, a: L, b: L) -> Point:
        """两个关键点中点的像素坐标（常用于髋中点、肩中点）。"""
        pa, pb = self.pixel(a), self.pixel(b)
        return ((pa[0] + pb[0]) / 2.0, (pa[1] + pb[1]) / 2.0)

    def pixel_span(self, a: L, b: L) -> float:
        """两点间的像素距离。常用于估计人体尺度（躯干长、肩宽）。"""
        pa, pb = self.pixel(a), self.pixel(b)
        return ((pa[0] - pb[0]) ** 2 + (pa[1] - pb[1]) ** 2) ** 0.5

    # ---- 世界坐标 ----

    @property
    def has_world(self) -> bool:
        """本帧是否带米制世界坐标。ML Kit 后端恒为 False。"""
        return self.world_landmarks is not None

    def world(self, idx: L) -> tuple[float, float, float] | None:
        """世界坐标点（米），无则返回 ``None``。

        **不要用返回值判断可用性后填 0** —— 依赖世界坐标的特征在缺失时必须
        整体置 ``None``，见 docs/domain-layer-design.md §0 铁律二。
        """
        if self.world_landmarks is None:
            return None
        lm = self.world_landmarks[idx]
        return (lm.x, lm.y, lm.z)

    # ---- 可见性 ----

    def visibility(self, idx: L) -> float:
        return self.landmarks[idx].visibility

    def is_visible(self, idx: L, threshold: float) -> bool:
        return self.landmarks[idx].visibility >= threshold

    def all_visible(self, indices: Iterable[L], threshold: float) -> bool:
        return all(self.is_visible(i, threshold) for i in indices)

    def mean_visibility(self, indices: Iterable[L] | None = None) -> float:
        idxs = list(indices) if indices is not None else list(L)
        if not idxs:
            raise PoseFrameError("mean_visibility 的指标集合为空，均值无定义")
        return sum(self.visibility(i) for i in idxs) / len(idxs)

    # ---- 人体尺度参考 ----

    def torso_length(self) -> float:
        """躯干长（像素）：肩中点到髋中点的距离。

        用作 :func:`vitalteen_domain.geometry.dist_ratio` 的参考长度。
        **不可改用画面尺寸** —— 那样相机动一下特征就漂了。
        """
        return _distance(
            self.pixel_mid(L.LEFT_SHOULDER, L.RIGHT_SHOULDER),
            self.pixel_mid(L.LEFT_HIP, L.RIGHT_HIP),
        )

    def shoulder_width(self) -> float:
        """肩宽（像素）。"""
        return self.pixel_span(L.LEFT_SHOULDER, L.RIGHT_SHOULDER)

    def scaling_factor(self, idx: L) -> float:
        """世界坐标相对像素坐标的缩放系数（米/像素）。

        用于需要把像素量换算成米制量的场合，**前提是本帧有世界坐标**。
        深度不同的关键点缩放系数不同，因此按点计算而非全局一个常数。
        """
        world = self.world(idx)
        if world is None:
            raise PoseFrameError("本帧无世界坐标，无法计算缩放系数")
        pixel = self.pixel(idx)
        # 像素坐标 y 向下、世界坐标 y 向上，这里用绝对值避免符号混淆
        top = self.pixel(L.NOSE)
        world_top = self.world(L.NOSE)
        assert world_top is not None  # 由 has_world 保证
        px_len = _distance(top, pixel)
        world_len = ((world_top[0] - world[0]) ** 2 + (world_top[1] - world[1]) ** 2) ** 0.5
        if px_len < 1e-9:
            raise PoseFrameError("参考长度过小，无法计算缩放系数")
        return world_len / px_len


def _distance(a: Point, b: Point) -> float:
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


def joint_angle(frame: PoseFrame, a: L, vertex: L, c: L) -> float:
    """关节夹角（度）—— 三点的像素坐标在函数内部完成还原。

    这是推荐的使用方式：把归一化→像素的换算封在内部，调用方无从写错。

    Raises:
        vitalteen_domain.geometry.DegenerateGeometryError: 向量零长。
    """
    return angle3(frame.pixel(a), frame.pixel(vertex), frame.pixel(c))


def frames_from_json(
    payload: Sequence[dict], frame_width: int, frame_height: int
) -> list[PoseFrame]:
    """从 golden fixture / 录制数据构造帧序列。

    期望每项形如::

        {"timestamp_ms": 33, "landmarks": [{"x":..,"y":..,"z":..,"visibility":..}, ...],
         "world_landmarks": null}

    供测试与离线回放使用。
    """
    frames: list[PoseFrame] = []
    for raw in payload:
        lms = tuple(
            Landmark(
                x=float(p["x"]),
                y=float(p["y"]),
                z=float(p.get("z", 0.0)),
                visibility=float(p.get("visibility", 1.0)),
            )
            for p in raw["landmarks"]
        )
        raw_world = raw.get("world_landmarks")
        # 用 `is not None` 而非真值判断：空列表 [] 既不满足「33 点」契约、
        # 也不等于 None，应当交由 PoseFrame 的构造校验抛出，而不是被静默当作缺失。
        world = (
            tuple(
                Landmark(
                    x=float(p["x"]),
                    y=float(p["y"]),
                    z=float(p.get("z", 0.0)),
                    visibility=float(p.get("visibility", 1.0)),
                )
                for p in raw_world
            )
            if raw_world is not None
            else None
        )
        frames.append(
            PoseFrame(
                landmarks=lms,
                world_landmarks=world,
                frame_width=frame_width,
                frame_height=frame_height,
                timestamp_ms=int(raw.get("timestamp_ms", 0)),
            )
        )
    return frames
