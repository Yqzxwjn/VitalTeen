"""VitalTeen 数据集管线、微调与评测。

规划中的模块（见 ``ml/README.md``）：

- :mod:`~vitalteen_ml.calibration` —— 置信度校准与评测（**已实现**）
- ``datasets`` —— 公开数据集的格式转换（COCO 17 → BlazePose 33 等），待数据落地
- ``samples`` —— 特征 → Laya 决策样本（``state`` + ``choice``/``score``/``noul``）
- ``finetune`` —— 训练驱动与超参配置

当前只实现了校准与评测，因为它是**不依赖任何数据就能建、能测**的那一部分，
而它测的恰好是本项目最大的风险：Laya 出厂状态的置信度不可信
（中文 ECE 0.314，且答错时置信度可达 0.91）。
"""

from __future__ import annotations

from .calibration import (
    CalibrationError,
    Evaluation,
    TemperatureFit,
    apply_temperature,
    comparison_table,
    correctness,
    evaluate,
    expected_calibration_error,
    fit_temperature,
    negative_log_likelihood,
    normalize,
    predicted_labels,
    top_confidence,
)

__version__ = "0.1.0"

__all__ = [
    "CalibrationError",
    "Evaluation",
    "TemperatureFit",
    "__version__",
    "apply_temperature",
    "comparison_table",
    "correctness",
    "evaluate",
    "expected_calibration_error",
    "fit_temperature",
    "negative_log_likelihood",
    "normalize",
    "predicted_labels",
    "top_confidence",
]
