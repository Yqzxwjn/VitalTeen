"""BlazePose 33 关键点索引与分组。

坐标系约定见 docs/domain-layer-design.md §1。
本模块只定义索引常量与分组，不含任何几何计算。
"""

from __future__ import annotations

from enum import IntEnum


class L(IntEnum):
    """BlazePose 33 关键点索引。

    33 点是 COCO 17 点的超集。多出的脚跟(29/30)、脚尖(31/32) 是深蹲脚跟离地
    与立定跳远起跳判定的必需点；手部(17-22) 用于握姿辅助；耳(7/8)、嘴(9/10)
    用于仰卧起坐抱头与引体向上过杠近似。
    """

    NOSE = 0
    LEFT_EYE_INNER = 1
    LEFT_EYE = 2
    LEFT_EYE_OUTER = 3
    RIGHT_EYE_INNER = 4
    RIGHT_EYE = 5
    RIGHT_EYE_OUTER = 6
    LEFT_EAR = 7
    RIGHT_EAR = 8
    MOUTH_LEFT = 9
    MOUTH_RIGHT = 10
    LEFT_SHOULDER = 11
    RIGHT_SHOULDER = 12
    LEFT_ELBOW = 13
    RIGHT_ELBOW = 14
    LEFT_WRIST = 15
    RIGHT_WRIST = 16
    LEFT_PINKY = 17
    RIGHT_PINKY = 18
    LEFT_INDEX = 19
    RIGHT_INDEX = 20
    LEFT_THUMB = 21
    RIGHT_THUMB = 22
    LEFT_HIP = 23
    RIGHT_HIP = 24
    LEFT_KNEE = 25
    RIGHT_KNEE = 26
    LEFT_ANKLE = 27
    RIGHT_ANKLE = 28
    LEFT_HEEL = 29
    RIGHT_HEEL = 30
    LEFT_FOOT_INDEX = 31
    RIGHT_FOOT_INDEX = 32


N_LANDMARKS = 33

#: 左右同名点配对 (left, right)，用于对称性计算
SYMMETRIC_PAIRS: tuple[tuple[L, L], ...] = (
    (L.LEFT_SHOULDER, L.RIGHT_SHOULDER),
    (L.LEFT_ELBOW, L.RIGHT_ELBOW),
    (L.LEFT_WRIST, L.RIGHT_WRIST),
    (L.LEFT_HIP, L.RIGHT_HIP),
    (L.LEFT_KNEE, L.RIGHT_KNEE),
    (L.LEFT_ANKLE, L.RIGHT_ANKLE),
    (L.LEFT_HEEL, L.RIGHT_HEEL),
    (L.LEFT_FOOT_INDEX, L.RIGHT_FOOT_INDEX),
)

#: 常用分组
UPPER_BODY = (L.LEFT_SHOULDER, L.RIGHT_SHOULDER, L.LEFT_ELBOW, L.RIGHT_ELBOW)
LOWER_BODY = (
    L.LEFT_HIP,
    L.RIGHT_HIP,
    L.LEFT_KNEE,
    L.RIGHT_KNEE,
    L.LEFT_ANKLE,
    L.RIGHT_ANKLE,
)
FEET = (L.LEFT_HEEL, L.RIGHT_HEEL, L.LEFT_FOOT_INDEX, L.RIGHT_FOOT_INDEX)

#: COCO 17 点在本体系中对应的索引。
#: 仅用于与外部数据集（多为 COCO 格式）对齐，**本项目的特征层不使用该降维路径**。
COCO17_FROM_BLAZE33: tuple[L, ...] = (
    L.NOSE,
    L.LEFT_EYE,
    L.RIGHT_EYE,
    L.LEFT_EAR,
    L.RIGHT_EAR,
    L.LEFT_SHOULDER,
    L.RIGHT_SHOULDER,
    L.LEFT_ELBOW,
    L.RIGHT_ELBOW,
    L.LEFT_WRIST,
    L.RIGHT_WRIST,
    L.LEFT_HIP,
    L.RIGHT_HIP,
    L.LEFT_KNEE,
    L.RIGHT_KNEE,
    L.LEFT_ANKLE,
    L.RIGHT_ANKLE,
)
