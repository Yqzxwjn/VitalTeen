"""几何算子。

**坐标系铁律（docs/domain-layer-design.md §1.2 约束 A）**

本模块所有算子接受的 `Point` 都是【像素坐标】，不是归一化坐标。
归一化坐标 x,y ∈ [0,1] 按图宽/图高分别折算，直接在该空间算角会被画幅宽高比
扭曲（16:9 画面上一个正圆会被算成椭圆）。调用方必须先通过
`PoseFrame.pixel()` 还原，不要自己乘。

**图像坐标系的 y 轴向下**，所有带符号的角度算子都以此为前提定义。
"""

from __future__ import annotations

import math
from typing import TypeAlias

Point: TypeAlias = tuple[float, float]

_EPS = 1e-9


class DegenerateGeometryError(ValueError):
    """几何退化：两点重合、向量零长，或角度无定义。

    调用方（特征层）应当捕获本异常并把该特征置为 ``None``，而不是填 0。
    见 docs/domain-layer-design.md §0 铁律二。
    """


def _sub(a: Point, b: Point) -> Point:
    return (a[0] - b[0], a[1] - b[1])


def _norm(v: Point) -> float:
    return math.hypot(v[0], v[1])


def _dot(a: Point, b: Point) -> float:
    return a[0] * b[0] + a[1] * b[1]


def _clamp(x: float, lo: float, hi: float) -> float:
    return lo if x < lo else hi if x > hi else x


def _normalize_signed_degrees(deg: float) -> float:
    """把带符号角度归一到 ``(-180, 180]``，并消除负零。

    两处 IEEE 754 的细节会在这里咬人：

    1. ``math.atan2(-0.0, -100.0)`` 返回 ``-π`` 而非 ``+π`` —— **负零的符号参与了
       象限判定**。于是「水平向左」的线段得到 ``-180.0``，落在本模块 docstring 声明的
       开区间之外，且与「竖直向下」得到 ``+180.0`` 的约定不一致。
       整数输入时 ``-0`` 就是 ``+0``，所以这个陷阱只在浮点路径上出现 ——
       而真实调用链上 :meth:`~vitalteen_domain.pose.PoseFrame.pixel` 返回的正是浮点。
    2. ``math.atan2(-0.0, 100.0)`` 返回 ``-0.0``，会原样泄漏给下游。

    两者都不影响角度的大小，但会让**跨语言比对出现假不等**：本项目的 golden fixtures
    要求 Python 参考实现与 Dart 端侧实现给出完全一致的数值
    （docs/domain-layer-design.md §8），而 ``-180.0 != 180.0`` 是可观察的差异，
    JSON 序列化出的 ``-0.0`` 同理。
    """
    if deg <= -180.0:
        return deg + 360.0
    return deg + 0.0  # -0.0 + 0.0 == +0.0，其余情况为恒等


def distance(a: Point, b: Point) -> float:
    """两点欧氏距离（像素）。"""
    return _norm(_sub(a, b))


def angle3(a: Point, b: Point, c: Point) -> float:
    """顶点 ``b`` 处，向量 BA 与 BC 的夹角，单位为度，取值 [0, 180]。

    >>> angle3((0.0, 0.0), (0.0, 100.0), (100.0, 100.0))
    90.0

    Raises:
        DegenerateGeometryError: 若 A 或 C 与顶点 B 重合（向量零长）。
    """
    ba = _sub(a, b)
    bc = _sub(c, b)
    nba, nbc = _norm(ba), _norm(bc)
    if nba < _EPS or nbc < _EPS:
        raise DegenerateGeometryError("angle3 的向量长度为 0，角度无定义")
    cos = _clamp(_dot(ba, bc) / (nba * nbc), -1.0, 1.0)
    return math.degrees(math.acos(cos))


def tilt_from_vertical(a: Point, b: Point) -> float:
    """线段 a→b 相对图像竖直方向的带符号夹角（度）。

    竖直向上（图像中即 y 减小方向）为 0；向图像右侧倾斜为正，左侧为负。
    取值范围 (-180, 180]。

    用于躯干前倾角、肢体倾角。注意「前倾」的正负方向由机位决定：
    侧拍时人面朝图像哪一侧，决定了前倾是正还是负 —— 调用方需自行取绝对值
    或结合机位定义符号。
    """
    v = _sub(b, a)
    if _norm(v) < _EPS:
        raise DegenerateGeometryError("tilt_from_vertical 的线段长度为 0")
    return _normalize_signed_degrees(math.degrees(math.atan2(v[0], -v[1])))


def tilt_from_horizontal(a: Point, b: Point) -> float:
    """线段 a→b 相对图像水平方向的带符号夹角（度）。

    水平向右为 0，向上倾斜为正。取值范围 (-180, 180]。
    用于大腿/小腿倾角 —— 「大腿接近水平」是平行蹲的判据之一。
    """
    v = _sub(b, a)
    if _norm(v) < _EPS:
        raise DegenerateGeometryError("tilt_from_horizontal 的线段长度为 0")
    return _normalize_signed_degrees(math.degrees(math.atan2(-v[1], v[0])))


def dist_ratio(p: Point, q: Point, ref_a: Point, ref_b: Point) -> float:
    """两点距离与参考线段长度之比（无量纲）。

    参考长度必须取自人体本身（躯干长、肩宽等），**不可用画面尺寸** ——
    否则相机距离一变，特征就漂移。

    Raises:
        DegenerateGeometryError: 参考线段长度为 0。
    """
    ref_len = distance(ref_a, ref_b)
    if ref_len < _EPS:
        raise DegenerateGeometryError("dist_ratio 的参考线段长度为 0")
    return distance(p, q) / ref_len


def symmetry_index(left: float, right: float) -> float:
    """左右对称指数 ``2|L-R| / |L+R|``，0 表示完全对称。

    **前提**：L 与 R 必须是同尺度、同量纲的量（例如左右膝角）。它是对相对
    偏差的度量，量纲约掉，因此可直接跨指标比较。

    分母取绝对值是为了容纳带符号输入（如左右两侧的带符号倾角）：此时两者之和
    可能为负，不取绝对值会让指数变成负数，「对称性」这个语义就破了。
    对既定的非负输入（角度、距离、比值），两种写法完全等价。

    Raises:
        DegenerateGeometryError: 左右之和为 0（无定义）。
    """
    total = left + right
    if abs(total) < _EPS:
        raise DegenerateGeometryError("symmetry_index 的左右之和为 0")
    return 2.0 * abs(left - right) / abs(total)


def midpoint(a: Point, b: Point) -> Point:
    """两点中点。"""
    return ((a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0)


def signed_offset(p: Point, a: Point, b: Point) -> float:
    """点 ``p`` 到直线 a→b 的带符号垂距（像素）。

    在图像坐标系（y 向下）中，正值表示 p 位于 a→b 的顺时针一侧。
    用于判断膝点落在「髋-踝连线」的内侧还是外侧（膝内扣判定）。

    注意：符号约定依赖机位 —— 正视拍摄时，同一条腿的「内侧」在画面上的
    顺时针方向是固定的，因此调用方需按左腿/右腿分别定号。
    """
    ab = _sub(b, a)
    length = _norm(ab)
    if length < _EPS:
        raise DegenerateGeometryError("signed_offset 的基线长度为 0")
    ap = _sub(p, a)
    cross = ab[0] * ap[1] - ab[1] * ap[0]
    return cross / length


def angular_velocity_deg_s(prev_deg: float, curr_deg: float, dt_ms: float) -> float:
    """角度变化率（度/秒）。

    Raises:
        DegenerateGeometryError: dt_ms 非正（时间戳重复或乱序）。
    """
    if dt_ms <= 0:
        raise DegenerateGeometryError("angular_velocity_deg_s 的 dt_ms 必须为正")
    return (curr_deg - prev_deg) / (dt_ms / 1000.0)
