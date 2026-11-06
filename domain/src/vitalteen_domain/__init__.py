"""VitalTeen 领域层参考实现。

这是**参考实现**，不是端侧实现。端侧在 ``app/lib/domain/``（Dart）。两者必须
通过 ``shared/fixtures/`` 里的同一套 golden 测试向量 —— 特征若在训练期与推理期
出现细微差异，模型会静默失效且极难定位，详见 docs/domain-layer-design.md §8。

分层：

- :mod:`~vitalteen_domain.landmarks` — 33 关键点索引与分组
- :mod:`~vitalteen_domain.geometry` — 纯几何算子（像素坐标）
- :mod:`~vitalteen_domain.pose` — 姿态帧对象，强制执行坐标还原
- :mod:`~vitalteen_domain.filters` — 中值 + One Euro 平滑
- :mod:`~vitalteen_domain.features` — 特征提取
- :mod:`~vitalteen_domain.thresholds` — 阈值治理（来源类型与核定状态）
- :mod:`~vitalteen_domain.rules` — 错误规则引擎
- :mod:`~vitalteen_domain.state_machine` — 通用动作状态机（三条防抖机制）
"""

from __future__ import annotations

from .features import (
    FEATURE_SPECS,
    FEATURE_SPECS_BY_CODE,
    CameraView,
    ComputeFn,
    FeatureExtractor,
    FeatureSpec,
    FeatureValue,
    FrameFeatures,
)
from .filters import LandmarkSmoother, MedianFilter, OneEuroFilter
from .geometry import (
    DegenerateGeometryError,
    Point,
    angle3,
    angular_velocity_deg_s,
    dist_ratio,
    distance,
    midpoint,
    signed_offset,
    symmetry_index,
    tilt_from_horizontal,
    tilt_from_vertical,
)
from .landmarks import N_LANDMARKS, SYMMETRIC_PAIRS, L
from .pose import (
    Landmark,
    PoseFrame,
    PoseFrameError,
    frames_from_json,
    joint_angle,
)
from .rules import (
    Deviation,
    Direction,
    Fault,
    FaultStat,
    Phase,
    Reduce,
    RepWindow,
    Rule,
    RuleEngine,
    SetSummary,
)
from .state_machine import (
    Guard,
    Signals,
    StateMachine,
    StateMachineError,
    StateUpdate,
    Transition,
)
from .thresholds import SourceType, Threshold, ThresholdError, ThresholdTable

__version__ = "0.1.0"

__all__ = [
    "FEATURE_SPECS",
    "FEATURE_SPECS_BY_CODE",
    "N_LANDMARKS",
    "SYMMETRIC_PAIRS",
    "CameraView",
    "ComputeFn",
    "DegenerateGeometryError",
    "Deviation",
    "Direction",
    "Fault",
    "FaultStat",
    "FeatureExtractor",
    "FeatureSpec",
    "FeatureValue",
    "FrameFeatures",
    "Guard",
    "L",
    "Landmark",
    "LandmarkSmoother",
    "MedianFilter",
    "OneEuroFilter",
    "Phase",
    "Point",
    "PoseFrame",
    "PoseFrameError",
    "Reduce",
    "RepWindow",
    "Rule",
    "RuleEngine",
    "SetSummary",
    "Signals",
    "SourceType",
    "StateMachine",
    "StateMachineError",
    "StateUpdate",
    "Threshold",
    "ThresholdError",
    "ThresholdTable",
    "Transition",
    "__version__",
    "angle3",
    "angular_velocity_deg_s",
    "dist_ratio",
    "distance",
    "frames_from_json",
    "joint_angle",
    "midpoint",
    "signed_offset",
    "symmetry_index",
    "tilt_from_horizontal",
    "tilt_from_vertical",
]
