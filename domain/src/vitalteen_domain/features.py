"""特征提取层。

把一帧 :class:`~vitalteen_domain.pose.PoseFrame` 变成一组带元信息的
:class:`FeatureValue`，供状态机与规则引擎消费。

**每个特征必须携带自己的可用性。** 这是 docs/domain-layer-design.md §0 铁律二
的落地：算不出来的特征输出 ``None`` 并说明原因，绝不用 0 或哨兵值冒充。
下游据此决定降权或弃权 —— 一个编造出来的 0 度膝角会被规则引擎当成
「膝盖完全对折」，比缺失危险得多。

**机位依赖是显式声明的。** 额状面膝角只在正视机位下有定义，侧拍时它算出来的
是投影角，毫无意义。因此每个特征声明适用的机位集合，不匹配则该帧直接判不可用。
"""

from __future__ import annotations

import math
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from types import MappingProxyType
from typing import Literal, TypeAlias

from .geometry import (
    DegenerateGeometryError,
    angle3,
    signed_offset,
    symmetry_index,
    tilt_from_horizontal,
    tilt_from_vertical,
)
from .landmarks import L
from .pose import PoseFrame

CameraView: TypeAlias = Literal["frontal", "sagittal", "oblique45"]
"""拍摄机位。特征对机位的依赖见各 :class:`FeatureSpec` 的 ``views`` 字段。

- ``frontal`` 正视（额状面）：判定膝内扣、左右对称、重心偏移
- ``sagittal`` 侧视（矢状面）：判定下蹲深度、躯干前倾、脚跟离地
- ``oblique45`` 斜前 45°：折中机位，部分动作可兼顾
"""

ANY_VIEW: tuple[CameraView, ...] = ("frontal", "sagittal", "oblique45")

ComputeFn: TypeAlias = Callable[[PoseFrame], float]


@dataclass(frozen=True, slots=True)
class FeatureValue:
    """一个特征的取值与元信息。

    Attributes:
        value: 数值；不可用时为 ``None``。
        valid: ``value is not None`` 的显式表达，便于下游过滤。
        invalid_reason: 不可用的原因，取值之一：

            - ``"low_visibility"`` —— 依赖的关键点可见性不足
            - ``"view_mismatch"`` —— 当前机位下该特征无定义
            - ``"degenerate"`` —— 几何退化（两点重合、参考长度为零等）
            - ``"no_world_landmarks"`` —— 依赖米制世界坐标，但当前后端不提供
    """

    code: str
    value: float | None
    unit: str
    coord_space: str
    valid: bool
    invalid_reason: str | None = None

    @classmethod
    def unavailable(cls, code: str, unit: str, coord_space: str, reason: str) -> FeatureValue:
        return cls(
            code=code,
            value=None,
            unit=unit,
            coord_space=coord_space,
            valid=False,
            invalid_reason=reason,
        )


@dataclass(frozen=True, slots=True)
class FrameFeatures:
    """一帧的全部特征。"""

    timestamp_ms: int
    values: Mapping[str, FeatureValue]

    def get(self, code: str) -> float | None:
        fv = self.values.get(code)
        return fv.value if fv is not None else None

    def is_valid(self, code: str) -> bool:
        fv = self.values.get(code)
        return fv is not None and fv.valid

    def as_signals(self) -> dict[str, float | None]:
        """转成状态机需要的 ``signals`` 映射。"""
        return {code: fv.value for code, fv in self.values.items()}


@dataclass(frozen=True, slots=True)
class FeatureSpec:
    """特征定义。

    Attributes:
        requires: 计算所需的关键点。任一可见性不足即判不可用。
        views: 适用的机位集合。空元组表示任意机位均可。
        needs_world: 是否依赖米制世界坐标（ML Kit 后端不提供，此时恒判不可用）。
    """

    code: str
    unit: str
    coord_space: str
    requires: tuple[L, ...]
    compute: ComputeFn
    views: tuple[CameraView, ...] = ()
    needs_world: bool = False


# ==========================================================================
# 计算函数
#
# 用「命名工厂 + 闭包」而不是在循环里写 `lambda f, h=hip, k=knee: ...`：
# 后者的默认参数是为了绕开循环变量的晚绑定才存在的，读代码的人看到的是
# 一串无意义的 `h=`、`k=`、`an=`，而真正的意图（「膝角 = 髋-膝-踝三点夹角」）
# 被淹没。本模块是 Dart 端侧移植的基准，意图必须一眼可见。
# ==========================================================================


def _joint_angle_fn(a: L, vertex: L, c: L) -> ComputeFn:
    """三点夹角。``vertex`` 是角的顶点。"""

    def compute(f: PoseFrame) -> float:
        return angle3(f.pixel(a), f.pixel(vertex), f.pixel(c))

    return compute


def _tilt_horizontal_fn(a: L, b: L) -> ComputeFn:
    """线段 a→b 相对水平方向的倾角。用于大腿/小腿。"""

    def compute(f: PoseFrame) -> float:
        return tilt_from_horizontal(f.pixel(a), f.pixel(b))

    return compute


def _heel_rise_fn(heel: L, toe: L) -> ComputeFn:
    """脚跟相对脚尖的抬升量，以足长归一。

    图像坐标 y 向下，因此「脚跟比脚尖高」表现为 heel.y < toe.y，
    取 ``(toe.y - heel.y)`` 使**正值代表脚跟抬起**，符合直觉。

    注意这是相对量：赤足/穿鞋、自然站姿差异都会影响基线，
    因此规则层必须拿它与该用户的站立校准值比较，不能直接对绝对值设阈值。
    """

    def compute(f: PoseFrame) -> float:
        p_heel, p_toe = f.pixel(heel), f.pixel(toe)
        foot_len = math.dist(p_heel, p_toe)
        if foot_len < 1e-9:
            raise DegenerateGeometryError("足长为 0，无法归一")
        return (p_toe[1] - p_heel[1]) / foot_len

    return compute


def _frontal_knee_angle_fn(hip: L, knee: L, ankle: L) -> ComputeFn:
    """额状面膝角：髋→膝 与 膝→踝 两向量的夹角，0° 表示完全成一条直线。

    **仅在正视机位下有定义。** 侧拍时该量退化为投影角，与本特征要表达的
    下肢额状面排列毫无关系。

    需要留意的是：2D 视频对下肢额状面运动的效度本身存在学术争议，
    且同类测量的最小可检测差异约 8°。因此本特征的产出**不应驱动硬性「犯规」判定**，
    只适合做「关注/明显」两级提示。见 docs/domain-layer-design.md §5.2。
    """

    def compute(f: PoseFrame) -> float:
        p_hip, p_knee, p_ankle = f.pixel(hip), f.pixel(knee), f.pixel(ankle)
        v1 = (p_knee[0] - p_hip[0], p_knee[1] - p_hip[1])
        v2 = (p_ankle[0] - p_knee[0], p_ankle[1] - p_knee[1])
        n1 = math.hypot(*v1)
        n2 = math.hypot(*v2)
        if n1 < 1e-9 or n2 < 1e-9:
            raise DegenerateGeometryError("额状面膝角的向量长度为 0")
        cos = max(-1.0, min(1.0, (v1[0] * v2[0] + v1[1] * v2[1]) / (n1 * n2)))
        return math.degrees(math.acos(cos))

    return compute


def _frontal_knee_offset_fn(hip: L, knee: L, ankle: L) -> ComputeFn:
    """膝点相对「髋-踝连线」的带符号偏移，以大腿长归一。

    正值 = 膝点位于该连线的图像顺时针一侧。**「内侧」对应哪个符号取决于
    拍摄的是左腿还是右腿**，由规则层按腿别定号 —— 本层只给几何事实，
    不替体育判据做假设。
    """

    def compute(f: PoseFrame) -> float:
        knee_len = f.pixel_span(hip, knee)
        if knee_len < 1e-9:
            raise DegenerateGeometryError("大腿长为 0，无法归一")
        return signed_offset(f.pixel(knee), f.pixel(hip), f.pixel(ankle)) / knee_len

    return compute


def _trunk_lean_fn(f: PoseFrame) -> float:
    """躯干相对图像竖直方向的带符号夹角（度）。

    符号取决于人在画面里面朝哪一侧，规则层应取绝对值或按机位定号。
    """
    return tilt_from_vertical(
        f.pixel_mid(L.LEFT_HIP, L.RIGHT_HIP),
        f.pixel_mid(L.LEFT_SHOULDER, L.RIGHT_SHOULDER),
    )


def _body_line_fn(f: PoseFrame) -> float:
    """肩中点-髋中点-踝中点夹角（度）。180° 表示完全成一条直线。

    用于俯卧撑/平板支撑的塌腰与撅臀判定。
    """
    return angle3(
        f.pixel_mid(L.LEFT_SHOULDER, L.RIGHT_SHOULDER),
        f.pixel_mid(L.LEFT_HIP, L.RIGHT_HIP),
        f.pixel_mid(L.LEFT_ANKLE, L.RIGHT_ANKLE),
    )


def _body_line_offset_fn(f: PoseFrame) -> float:
    """髋中点相对「肩中点→踝中点」这条线的有向偏离，以躯干长归一。

    **正 = 髋比连线更低（塌腰），负 = 髋比连线更高（撅臀）。**

    为什么不能用现成的 ``body_line_angle``：那是 :func:`angle3` 的夹角，
    值域 [0°, 180°]，塌腰与撅臀**都**只是让它变小 —— 两者完全同形，
    分不出是哪一种，而它们要给的纠正建议正好相反。

    符号取**重力方向**（图像 y 轴向下）而不是「连线的哪一侧」：
    ``signed_offset`` 那种约定依赖 a→b 的走向，而人面朝画面哪一边是随机的，
    同一个塌腰会得到一正一负，阈值就无法只写一个。手机大致水平这个前提
    与 :func:`tilt_from_vertical` / ``hip_height_ratio`` 是同一个。

    机位声明与 ``heel_rise_ratio_*`` 相同，理由也相同：这是个 y 方向的量，
    正视下「身体的前后方向」就是镜头方向本身。45° 下分母（躯干长）被方位压缩、
    分子不被压缩，读数偏大 —— 与 ``heel_rise_ratio`` 是同一类偏差，
    阈值表里那个 ``pending_review`` 就是留给真机标定的。
    """
    shoulder = f.pixel_mid(L.LEFT_SHOULDER, L.RIGHT_SHOULDER)
    hip = f.pixel_mid(L.LEFT_HIP, L.RIGHT_HIP)
    ankle = f.pixel_mid(L.LEFT_ANKLE, L.RIGHT_ANKLE)

    torso = f.torso_length()
    if torso < 1e-9:
        raise DegenerateGeometryError("躯干长为 0，无法归一")

    ux = ankle[0] - shoulder[0]
    uy = ankle[1] - shoulder[1]
    len2 = ux * ux + uy * uy
    if len2 < 1e-9:
        raise DegenerateGeometryError("肩-踝连线的长度为 0，偏离无定义")

    # 把髋点投影到连线上，只取 y 方向的差。投影参数夹到 [0, 1]：髋在这一段
    # 之外时（不该出现，但关键点抖动会造出来）比的是离得近的那个端点。
    t = ((hip[0] - shoulder[0]) * ux + (hip[1] - shoulder[1]) * uy) / len2
    t = min(1.0, max(0.0, t))
    return (hip[1] - (shoulder[1] + t * uy)) / torso


def _shoulder_height_fn(f: PoseFrame) -> float:
    """肩中点高出踝中点的像素高度差，以躯干长归一。

    **参照物是踝，不是画面** —— 单目没有世界坐标，画面上下的位移一半来自人
    自己的移动，所以量「上身起来了多少」只能拿一个跟着人走的东西当零点。
    仰卧起坐的踝自始至终贴在垫上（屈膝 90°、脚掌踩垫），所以它是最稳的那个零点；
    这正是这个量在别的动作上没有意义、只服务仰卧起坐的原因。

    典型读数（躯干长为单位）：仰卧平躺 ≈ 0，坐起到肩在髋正上方 ≈ 1.0 上下，
    站着 ≈ 1.5 以上。**单调**，所以可以直接当分段信号用。

    **分母被方位压缩、分子不被压缩**：分子是 y 方向的差，方位旋转改不了它；
    而躯干长在 45° 下按 cos 缩水，同一个姿势的读数于是整体偏大（约 1.4 倍）。
    与 ``body_line_offset_ratio`` / ``heel_rise_ratio`` 是同一类偏差，
    阈值表里那个 ``pending_review`` 就是留给真机标定的。

    机位声明同上：正视下「身体的前后方向」就是镜头方向本身，y 方向的差读不出来。
    """
    p_shoulder = f.pixel_mid(L.LEFT_SHOULDER, L.RIGHT_SHOULDER)
    p_ankle = f.pixel_mid(L.LEFT_ANKLE, L.RIGHT_ANKLE)
    torso = f.torso_length()
    if torso < 1e-9:
        raise DegenerateGeometryError("躯干长为 0，无法归一")
    return (p_ankle[1] - p_shoulder[1]) / torso


def _foot_height_fn(f: PoseFrame) -> float:
    """双脚脚尖中点高出**画面下缘**的像素高差，以躯干长归一。

    跳绳「人有没有离地」的那个量（``exercises/rope.py`` 的三条分段线）。

    **这是全仓库唯一一个拿画面当零点的特征。** 别的 y 方向量都刻意避开画面
    —— ``shoulder_height_ratio`` 的注释写了为什么：单目没有世界坐标，
    画面上下的位移一半来自人自己的移动。这里能用画面，理由只有一条：
    跳绳的判定前提就是**手机架稳不动**，于是画面下缘在一整组里是一个不动的
    水平面，而「离地」恰恰要相对地面、不能相对本人。换一个跟着人走的参照物
    （踝、髋），量出来的就变成了「脚相对身体抬多高」—— 那件事跳绳不需要知道。

    **参照点取脚尖而不是踝**：站立时人与地面的接触点是脚掌，踝在脚跟上方一两寸；
    而跳绳几乎全程用前脚掌着地、脚跟是抬着的，踝的高度于是自带一个
    「本人踮脚程度」的偏移（见 ``heel_rise_ratio_*``）。脚尖没有这个偏移 ——
    它落在哪儿，人就是站在哪儿。

    **绝对值只在同一组内可比**（机位高低决定了「画面下缘到脚尖」有多少像素），
    所以三条分段线全部记成相对**本人站立基线**的增量，
    标定那边采的就是这个特征（``BaselineKey.foot_height``）。
    """
    toe = f.pixel_mid(L.LEFT_FOOT_INDEX, L.RIGHT_FOOT_INDEX)
    torso = f.torso_length()
    if torso < 1e-9:
        raise DegenerateGeometryError("躯干长为 0，无法归一")
    return (f.frame_height - toe[1]) / torso


def _foot_gap_fn(f: PoseFrame) -> float:
    """左右脚尖的高度差（``|Δy|``），以躯干长归一。

    跳绳「是不是单脚落地」的那个量（``ROPE_SINGLE_LEG``）。

    双脚同时起落时两枚脚尖大致等高，这个量接近 0；一只脚先落、或独脚跳时
    按两只脚的高度差线性增长。

    **取绝对值而不是有符号差**：跳绳时先落地的是哪一只脚是随机的，
    有符号量的分布是双峰的，一条阈值写不出来。

    与 ``foot_height_ratio`` 共用「脚尖」这个参照点（理由相同：脚尖是接触点），
    但**不共用画面做零点** —— 差分把零点约掉了，所以这个量跨组、跨机位都可比。
    """
    left = f.pixel(L.LEFT_FOOT_INDEX)
    right = f.pixel(L.RIGHT_FOOT_INDEX)
    torso = f.torso_length()
    if torso < 1e-9:
        raise DegenerateGeometryError("躯干长为 0，无法归一")
    return abs(left[1] - right[1]) / torso


def _mouth_wrist_dy_fn(f: PoseFrame) -> float:
    """嘴中点相对腕中点的**有符号**高度差（嘴在腕上方为负），以躯干长归一。

    引体向上「下颌过杠」的量（``PULLUP_CHIN_NOT_OVER``）：双手握在杠上，
    所以**腕的高度就是杠的高度**，嘴高过腕即「下颌过杠」——
    这不是代理量，是一条几何恒等式，前提只有「手确实握在杠上」。

    **带符号是必须的**（与 ``foot_gap_ratio`` 取绝对值相反）：要判的是「过没过」，
    方向就是全部信息；取绝对值会把「挂在那里、嘴在手下」与「拉过头、嘴在手上面」
    压成同一个数。图像 y 轴朝下，所以**过杠时这个值是负的**。

    归一用躯干长（同 ``shoulder_height_ratio``），身高与镜头远近在里面约掉。

    **它是这一族里最脆弱的一个**：嘴是 33 点里可见性最低的几个点之一，
    而拉上去的时候上臂还可能遮住脸。取不到时按「不知道」处理（该帧不参与），
    所以规则那边**不会**因为遮挡而误报，但**遮挡会让这条判定静默地不生效** ——
    那是另一件事，写在 ``exercises/pullup.py`` 的文件头。
    """
    mouth = f.pixel_mid(L.MOUTH_LEFT, L.MOUTH_RIGHT)
    wrist = f.pixel_mid(L.LEFT_WRIST, L.RIGHT_WRIST)
    torso = f.torso_length()
    if torso < 1e-9:
        raise DegenerateGeometryError("躯干长为 0，无法归一")
    return (mouth[1] - wrist[1]) / torso


def _hip_height_fn(f: PoseFrame) -> float:
    """髋中点高出膝中点的像素高度差，以躯干长归一。

    直立时约 1.0；下蹲到大腿平行地面时趋近 0；蹲得更低则为负。
    这是 **ML Kit 后端（无世界坐标）下判定下蹲深度的主要替代量**。
    """
    p_hip = f.pixel_mid(L.LEFT_HIP, L.RIGHT_HIP)
    p_knee = f.pixel_mid(L.LEFT_KNEE, L.RIGHT_KNEE)
    torso = f.torso_length()
    if torso < 1e-9:
        raise DegenerateGeometryError("躯干长为 0，无法归一")
    return (p_knee[1] - p_hip[1]) / torso


def _pelvis_offset_fn(f: PoseFrame) -> float:
    """骨盆中点相对两踝中点的水平偏移，以肩宽归一。用于判定重心偏移。"""
    p_hip = f.pixel_mid(L.LEFT_HIP, L.RIGHT_HIP)
    p_ankle = f.pixel_mid(L.LEFT_ANKLE, L.RIGHT_ANKLE)
    width = f.shoulder_width()
    if width < 1e-9:
        raise DegenerateGeometryError("肩宽为 0，无法归一")
    return (p_hip[0] - p_ankle[0]) / width


def _frontal_knee_max_fn(f: PoseFrame) -> float:
    """左右额状面膝角中的较大者。

    膝内扣可能只发生在单侧，而规则引擎是按「指标越界帧数」计数的，因此需要一个
    能把两侧中最差的那一侧暴露出来的量。取较大者而非平均，是为了不让一侧的正常值
    掩盖另一侧的明显内扣。

    两侧都算不出时抛退化异常，由特征层统一转成「不可用」—— 与「两侧都正常」
    是两回事，不能混淆。
    """
    values: list[float] = []
    for hip, knee, ankle in (
        (L.LEFT_HIP, L.LEFT_KNEE, L.LEFT_ANKLE),
        (L.RIGHT_HIP, L.RIGHT_KNEE, L.RIGHT_ANKLE),
    ):
        try:
            values.append(_frontal_knee_angle_fn(hip, knee, ankle)(f))
        except DegenerateGeometryError:
            continue
    if not values:
        raise DegenerateGeometryError("两侧额状面膝角均不可计算")
    return max(values)


def _leg_spread_fn(f: PoseFrame) -> float:
    """两踝的横向间距，以肩宽归一。开合跳「开得够不够」的那个量。

    **用比值而不是像素差**：镜头远近、体型大小、以及机位倾斜造成的横向压缩，
    在分子分母上是同一个系数，比值把它约掉了。

    **只在正视机位下有定义**（见 ``views``）。45° 下分子分母的 ``cos`` 因子
    一阶相消、比值仍近似成立，但只到一阶为止 —— 透视（肩比踝离镜头近）、
    躯干前倾让肩线与踝线不在同一深度、以及 45° 下远侧腿常被近侧腿挡住，
    这三条会把比值推出百分比级的偏差，而且偏差随姿态漂。
    """
    width = f.shoulder_width()
    if width < 1e-9:
        raise DegenerateGeometryError("肩宽为 0，无法归一")
    return abs(f.pixel(L.LEFT_ANKLE)[0] - f.pixel(L.RIGHT_ANKLE)[0]) / width


def _shoulder_angle_min_fn(f: PoseFrame) -> float:
    """左右肩角中**较小**的那一个（度）。180° 表示手臂举过头顶。

    取较小者而不是较大者：这条量要回答的是「两只手臂**都**举到位了吗」，
    落后那一只才是判据。这一点与 ``_frontal_knee_max_fn`` 相反（那里取较大者，
    问的是「最差的那一侧有多差」）—— 两处都是各自规则要问的问题决定的，
    不是谁抄错了。
    """
    left = angle3(
        f.pixel(L.LEFT_HIP), f.pixel(L.LEFT_SHOULDER), f.pixel(L.LEFT_ELBOW)
    )
    right = angle3(
        f.pixel(L.RIGHT_HIP), f.pixel(L.RIGHT_SHOULDER), f.pixel(L.RIGHT_ELBOW)
    )
    return min(left, right)


def _knee_symmetry_fn(f: PoseFrame) -> float:
    """左右膝角的对称指数。0 表示完全对称。"""
    return symmetry_index(
        angle3(f.pixel(L.LEFT_HIP), f.pixel(L.LEFT_KNEE), f.pixel(L.LEFT_ANKLE)),
        angle3(f.pixel(L.RIGHT_HIP), f.pixel(L.RIGHT_KNEE), f.pixel(L.RIGHT_ANKLE)),
    )


# ==========================================================================
# 左右同名特征：同一套定义按侧别实例化，避免左右两套代码各自漂移
# ==========================================================================

_SIDES: dict[str, dict[str, L]] = {
    "L": {
        "hip": L.LEFT_HIP,
        "knee": L.LEFT_KNEE,
        "ankle": L.LEFT_ANKLE,
        "heel": L.LEFT_HEEL,
        "toe": L.LEFT_FOOT_INDEX,
        "shoulder": L.LEFT_SHOULDER,
        "elbow": L.LEFT_ELBOW,
        "wrist": L.LEFT_WRIST,
    },
    "R": {
        "hip": L.RIGHT_HIP,
        "knee": L.RIGHT_KNEE,
        "ankle": L.RIGHT_ANKLE,
        "heel": L.RIGHT_HEEL,
        "toe": L.RIGHT_FOOT_INDEX,
        "shoulder": L.RIGHT_SHOULDER,
        "elbow": L.RIGHT_ELBOW,
        "wrist": L.RIGHT_WRIST,
    },
}

_UPPER_TORSO: tuple[L, ...] = (
    L.LEFT_SHOULDER,
    L.RIGHT_SHOULDER,
    L.LEFT_HIP,
    L.RIGHT_HIP,
)
_LOWER_CHAIN: tuple[L, ...] = (
    L.LEFT_HIP,
    L.RIGHT_HIP,
    L.LEFT_KNEE,
    L.RIGHT_KNEE,
    L.LEFT_ANKLE,
    L.RIGHT_ANKLE,
)


def _side_specs() -> list[FeatureSpec]:
    """生成左右各自的关节角、额状面、脚跟抬升等特征。"""
    out: list[FeatureSpec] = []
    for side, p in _SIDES.items():
        out += [
            FeatureSpec(
                code=f"knee_angle_{side}",
                unit="deg",
                coord_space="pixel",
                requires=(p["hip"], p["knee"], p["ankle"]),
                compute=_joint_angle_fn(p["hip"], p["knee"], p["ankle"]),
            ),
            FeatureSpec(
                code=f"hip_angle_{side}",
                unit="deg",
                coord_space="pixel",
                requires=(p["shoulder"], p["hip"], p["knee"]),
                compute=_joint_angle_fn(p["shoulder"], p["hip"], p["knee"]),
            ),
            FeatureSpec(
                code=f"elbow_angle_{side}",
                unit="deg",
                coord_space="pixel",
                requires=(p["shoulder"], p["elbow"], p["wrist"]),
                compute=_joint_angle_fn(p["shoulder"], p["elbow"], p["wrist"]),
            ),
            FeatureSpec(
                code=f"shoulder_angle_{side}",
                unit="deg",
                coord_space="pixel",
                requires=(p["hip"], p["shoulder"], p["elbow"]),
                compute=_joint_angle_fn(p["hip"], p["shoulder"], p["elbow"]),
            ),
            FeatureSpec(
                code=f"thigh_tilt_{side}",
                unit="deg",
                coord_space="pixel",
                requires=(p["hip"], p["knee"]),
                compute=_tilt_horizontal_fn(p["hip"], p["knee"]),
            ),
            FeatureSpec(
                code=f"frontal_knee_angle_{side}",
                unit="deg",
                coord_space="pixel",
                requires=(p["hip"], p["knee"], p["ankle"]),
                compute=_frontal_knee_angle_fn(p["hip"], p["knee"], p["ankle"]),
                views=("frontal",),
            ),
            FeatureSpec(
                code=f"frontal_knee_offset_{side}",
                unit="ratio",
                coord_space="dimensionless",
                requires=(p["hip"], p["knee"], p["ankle"]),
                compute=_frontal_knee_offset_fn(p["hip"], p["knee"], p["ankle"]),
                views=("frontal",),
            ),
            FeatureSpec(
                code=f"heel_rise_ratio_{side}",
                unit="ratio",
                coord_space="dimensionless",
                requires=(p["heel"], p["toe"], p["ankle"]),
                compute=_heel_rise_fn(p["heel"], p["toe"]),
                views=("sagittal", "oblique45"),
            ),
        ]
    return out


def _specs() -> tuple[FeatureSpec, ...]:
    return (
        *_side_specs(),
        FeatureSpec(
            code="trunk_lean",
            unit="deg",
            coord_space="pixel",
            requires=_UPPER_TORSO,
            compute=_trunk_lean_fn,
        ),
        FeatureSpec(
            code="body_line_angle",
            unit="deg",
            coord_space="pixel",
            requires=(*_UPPER_TORSO, L.LEFT_ANKLE, L.RIGHT_ANKLE),
            compute=_body_line_fn,
            views=("sagittal", "oblique45"),
        ),
        FeatureSpec(
            code="hip_height_ratio",
            unit="ratio",
            coord_space="dimensionless",
            requires=(*_UPPER_TORSO, L.LEFT_KNEE, L.RIGHT_KNEE),
            compute=_hip_height_fn,
        ),
        FeatureSpec(
            code="pelvis_offset_ratio",
            unit="ratio",
            coord_space="dimensionless",
            requires=(*_LOWER_CHAIN, L.LEFT_SHOULDER, L.RIGHT_SHOULDER),
            compute=_pelvis_offset_fn,
            views=("frontal",),
        ),
        FeatureSpec(
            code="knee_symmetry",
            unit="ratio",
            coord_space="dimensionless",
            requires=_LOWER_CHAIN,
            compute=_knee_symmetry_fn,
        ),
        FeatureSpec(
            code="frontal_knee_angle_max",
            unit="deg",
            coord_space="pixel",
            requires=(
                L.LEFT_HIP,
                L.RIGHT_HIP,
                L.LEFT_KNEE,
                L.RIGHT_KNEE,
                L.LEFT_ANKLE,
                L.RIGHT_ANKLE,
            ),
            compute=_frontal_knee_max_fn,
            views=("frontal",),
        ),
        FeatureSpec(
            code="torso_length_px",
            unit="px",
            coord_space="pixel",
            requires=_UPPER_TORSO,
            compute=lambda f: f.torso_length(),
        ),
        FeatureSpec(
            code="shoulder_width_px",
            unit="px",
            coord_space="pixel",
            requires=(L.LEFT_SHOULDER, L.RIGHT_SHOULDER),
            compute=lambda f: f.shoulder_width(),
        ),
        # 以下两个是**成对/组合量**（像 ``frontal_knee_angle_max``），
        # 不属于按左右实例化的那一族。**顺序与 Dart 的 `_buildSpecs()` 一致**。
        FeatureSpec(
            code="leg_spread_ratio",
            unit="ratio",
            coord_space="dimensionless",
            requires=(
                L.LEFT_ANKLE,
                L.RIGHT_ANKLE,
                L.LEFT_SHOULDER,
                L.RIGHT_SHOULDER,
            ),
            compute=_leg_spread_fn,
            views=("frontal",),
        ),
        FeatureSpec(
            code="shoulder_angle_min",
            unit="deg",
            coord_space="pixel",
            requires=(
                L.LEFT_HIP,
                L.RIGHT_HIP,
                L.LEFT_SHOULDER,
                L.RIGHT_SHOULDER,
                L.LEFT_ELBOW,
                L.RIGHT_ELBOW,
            ),
            compute=_shoulder_angle_min_fn,
        ),
        FeatureSpec(
            code="body_line_offset_ratio",
            unit="ratio",
            coord_space="dimensionless",
            requires=(
                L.LEFT_SHOULDER,
                L.RIGHT_SHOULDER,
                L.LEFT_HIP,
                L.RIGHT_HIP,
                L.LEFT_ANKLE,
                L.RIGHT_ANKLE,
            ),
            compute=_body_line_offset_fn,
            views=("sagittal", "oblique45"),
        ),
        FeatureSpec(
            code="shoulder_height_ratio",
            unit="ratio",
            coord_space="dimensionless",
            requires=(
                L.LEFT_SHOULDER,
                L.RIGHT_SHOULDER,
                L.LEFT_HIP,
                L.RIGHT_HIP,
                L.LEFT_ANKLE,
                L.RIGHT_ANKLE,
            ),
            compute=_shoulder_height_fn,
            views=("sagittal", "oblique45"),
        ),
        FeatureSpec(
            code="foot_height_ratio",
            unit="ratio",
            coord_space="dimensionless",
            requires=(
                L.LEFT_SHOULDER,
                L.RIGHT_SHOULDER,
                L.LEFT_HIP,
                L.RIGHT_HIP,
                L.LEFT_FOOT_INDEX,
                L.RIGHT_FOOT_INDEX,
            ),
            compute=_foot_height_fn,
            views=("sagittal", "oblique45"),
        ),
        FeatureSpec(
            code="foot_gap_ratio",
            unit="ratio",
            coord_space="dimensionless",
            requires=(
                L.LEFT_SHOULDER,
                L.RIGHT_SHOULDER,
                L.LEFT_HIP,
                L.RIGHT_HIP,
                L.LEFT_FOOT_INDEX,
                L.RIGHT_FOOT_INDEX,
            ),
            compute=_foot_gap_fn,
            views=("sagittal", "oblique45"),
        ),
        FeatureSpec(
            code="mouth_wrist_dy",
            unit="ratio",
            coord_space="dimensionless",
            requires=(
                L.LEFT_SHOULDER,
                L.RIGHT_SHOULDER,
                L.LEFT_HIP,
                L.RIGHT_HIP,
                L.MOUTH_LEFT,
                L.MOUTH_RIGHT,
                L.LEFT_WRIST,
                L.RIGHT_WRIST,
            ),
            compute=_mouth_wrist_dy_fn,
        ),
    )


FEATURE_SPECS: tuple[FeatureSpec, ...] = _specs()

FEATURE_SPECS_BY_CODE: Mapping[str, FeatureSpec] = MappingProxyType(
    {spec.code: spec for spec in FEATURE_SPECS}
)


class FeatureExtractor:
    """按帧提取全部特征。

    刻意「全量提取」而非「按需提取」：一帧的三角运算开销可忽略，而按需提取会
    引入「动作定义声明的特征集」与「实际计算的特征集」不一致的风险 ——
    这类不一致不会报错，只会让某个规则永远拿不到数据。动作定义只需从结果里
    挑选自己要用的特征。

    Args:
        visibility_threshold: 关键点可见性门控。低于此值的点视为不可用。
        camera_view: 当前机位。与特征声明的适用机位不匹配时该特征判不可用。
    """

    def __init__(
        self,
        *,
        visibility_threshold: float = 0.5,
        camera_view: CameraView = "frontal",
    ) -> None:
        self.visibility_threshold = visibility_threshold
        self.camera_view = camera_view

    def extract(self, frame: PoseFrame) -> FrameFeatures:
        out = {spec.code: self._one(spec, frame) for spec in FEATURE_SPECS}
        return FrameFeatures(timestamp_ms=frame.timestamp_ms, values=MappingProxyType(out))

    def _one(self, spec: FeatureSpec, frame: PoseFrame) -> FeatureValue:
        if spec.views and self.camera_view not in spec.views:
            return FeatureValue.unavailable(
                spec.code, spec.unit, spec.coord_space, "view_mismatch"
            )
        if spec.needs_world and not frame.has_world:
            return FeatureValue.unavailable(
                spec.code, spec.unit, spec.coord_space, "no_world_landmarks"
            )
        if not frame.all_visible(spec.requires, self.visibility_threshold):
            return FeatureValue.unavailable(
                spec.code, spec.unit, spec.coord_space, "low_visibility"
            )
        try:
            value = spec.compute(frame)
        except DegenerateGeometryError:
            return FeatureValue.unavailable(spec.code, spec.unit, spec.coord_space, "degenerate")
        return FeatureValue(
            code=spec.code,
            value=value,
            unit=spec.unit,
            coord_space=spec.coord_space,
            valid=True,
        )


__all__ = [
    "ANY_VIEW",
    "FEATURE_SPECS",
    "FEATURE_SPECS_BY_CODE",
    "CameraView",
    "ComputeFn",
    "FeatureExtractor",
    "FeatureSpec",
    "FeatureValue",
    "FrameFeatures",
]
