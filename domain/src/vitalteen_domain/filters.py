"""滤波与平滑。

三级流水线中的 L1（坐标级）与 L2（信号级），见 docs/domain-layer-design.md §3。

**为什么是「中值 → One Euro」而不是卡尔曼**

卡尔曼需要运动模型且参数难调，收益集中在锚点信号上。而姿态关键点的抖动特征是
「低速时抖得厉害、高速时跟随性要求高」，One Euro 恰好针对这一点：截止频率随速度
自适应 —— 静止时强平滑，快速运动时低延迟。代价是需要调 ``min_cutoff`` / ``beta``，
这两个参数属于工程默认值（非体育阈值），需按机型回归调参。

中值滤波放在前面是为了先干掉尖峰 —— 它对离群值的抑制是无条件的，
不像低通滤波那样会被一个巨大的野值拖出长尾。
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass, field, replace

from .pose import Landmark, PoseFrame

#: 时间戳重复（dt=0）时使用的兜底步长（秒）。
#: 真实相机流中偶发重复时间戳，直接除零会让滤波器炸掉。
#: 替代为 1ms 是工程折中：会产生一个偏大的瞬时速度估计，但被 d_cutoff 低通压住。
_DT_FALLBACK_S = 1e-3


@dataclass(slots=True)
class MedianFilter:
    """滑动窗口中值滤波。对离群值无条件抑制，不引入参数。"""

    window: int = 3

    # 必须声明为字段：dataclass(slots=True) 只为声明过的字段生成 __slots__，
    # 否则 __post_init__ 里的赋值会因为实例没有 __dict__ 而抛 AttributeError。
    _buf: deque[float] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        if self.window < 1:
            raise ValueError("window 必须 >= 1")
        if self.window % 2 == 0:
            raise ValueError("window 必须为奇数，否则中位数需插值，意义不明")
        self._buf = deque(maxlen=self.window)

    def __call__(self, value: float) -> float:
        self._buf.append(value)
        ordered = sorted(self._buf)
        return ordered[len(ordered) // 2]

    def reset(self) -> None:
        self._buf.clear()


class OneEuroFilter:
    """One Euro 滤波器（Casiez et al. 2012）。

    截止频率随信号速度自适应：

    - 低速 → 低截止频率 → 强平滑
    - 高速 → 高截止频率 → 低延迟

    Args:
        min_cutoff: 速度趋近 0 时的截止频率（Hz）。越小越平滑、延迟越大。
        beta: 速度对截止频率的影响系数。越大则快速运动时跟随越好、抖动越多。
        d_cutoff: 速度信号自身的截止频率（Hz），用于压制速度估计的噪声。
    """

    __slots__ = ("_dx_prev", "_initialised", "_x_prev", "beta", "d_cutoff", "min_cutoff")

    def __init__(self, min_cutoff: float = 1.0, beta: float = 0.02, d_cutoff: float = 1.0) -> None:
        if min_cutoff <= 0 or d_cutoff <= 0:
            raise ValueError("截止频率必须为正")
        if beta < 0:
            raise ValueError("beta 不能为负")
        self.min_cutoff = min_cutoff
        self.beta = beta
        self.d_cutoff = d_cutoff
        self._x_prev = 0.0
        self._dx_prev = 0.0
        self._initialised = False

    @staticmethod
    def _alpha(cutoff: float, dt: float) -> float:
        tau = 1.0 / (2.0 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def __call__(self, x: float, dt: float) -> float:
        """输入新样本与时间步长（秒），返回滤波后的值。

        首个样本直接原样返回 —— 没有历史，任何平滑都是编造。
        """
        if dt <= 0:
            dt = _DT_FALLBACK_S

        if not self._initialised:
            self._x_prev = x
            self._dx_prev = 0.0
            self._initialised = True
            return x

        dx = (x - self._x_prev) / dt
        a_d = self._alpha(self.d_cutoff, dt)
        dx_hat = a_d * dx + (1.0 - a_d) * self._dx_prev

        cutoff = self.min_cutoff + self.beta * abs(dx_hat)
        a = self._alpha(cutoff, dt)
        x_hat = a * x + (1.0 - a) * self._x_prev

        self._x_prev = x_hat
        self._dx_prev = dx_hat
        return x_hat

    def reset(self) -> None:
        self._x_prev = 0.0
        self._dx_prev = 0.0
        self._initialised = False


class LandmarkSmoother:
    """对一个 :class:`~vitalteen_domain.pose.PoseFrame` 的全部关键点做逐点逐轴平滑。

    顺序：中值 → One Euro。世界坐标若存在则同样处理。

    ``visibility`` **不做平滑** —— 它是置信度而非物理量，平滑它会制造出
    「看起来很确信」的假象，反而危害下游的门控判断。
    """

    def __init__(
        self,
        median_window: int = 3,
        min_cutoff: float = 1.0,
        beta: float = 0.02,
        d_cutoff: float = 1.0,
    ) -> None:
        self._median_window = median_window
        self._min_cutoff = min_cutoff
        self._beta = beta
        self._d_cutoff = d_cutoff
        self._medians: dict[tuple[str, int, str], MedianFilter] = {}
        self._euros: dict[tuple[str, int, str], OneEuroFilter] = {}
        self._last_ts_ms: int | None = None

    def _smooth_frame(
        self,
        landmarks: tuple[Landmark, ...],
        tag: str,
        timestamp_ms: int,
        dt: float,
    ) -> tuple[Landmark, ...]:
        out: list[Landmark] = []
        for i, lm in enumerate(landmarks):
            vals: dict[str, float] = {}
            for axis in ("x", "y", "z"):
                key = (tag, i, axis)
                med = self._medians.setdefault(key, MedianFilter(self._median_window))
                euro = self._euros.setdefault(
                    key,
                    OneEuroFilter(self._min_cutoff, self._beta, self._d_cutoff),
                )
                vals[axis] = euro(med(getattr(lm, axis)), dt)
            out.append(Landmark(**vals, visibility=lm.visibility))
        return tuple(out)

    def __call__(self, frame: PoseFrame) -> PoseFrame:
        if self._last_ts_ms is None:
            dt = _DT_FALLBACK_S
        else:
            dt = max((frame.timestamp_ms - self._last_ts_ms) / 1000.0, _DT_FALLBACK_S)
        self._last_ts_ms = frame.timestamp_ms

        smoothed = self._smooth_frame(frame.landmarks, "n", frame.timestamp_ms, dt)
        world = (
            self._smooth_frame(frame.world_landmarks, "w", frame.timestamp_ms, dt)
            if frame.world_landmarks is not None
            else None
        )
        return replace(frame, landmarks=smoothed, world_landmarks=world)

    def reset(self) -> None:
        """清空全部状态。长时间丢失关键点后重新入镜时应调用。"""
        self._medians.clear()
        self._euros.clear()
        self._last_ts_ms = None
