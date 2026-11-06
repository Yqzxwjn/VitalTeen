"""阈值治理。

本模块存在的唯一目的：**让工程师无法在代码里偷偷硬编码体育阈值**。

背景（docs/domain-layer-design.md §7）：本项目的阈值分两类，性质完全不同 ——

- **体育阈值**（关节角合格线、错误严重度切分）来自国标或运动科学文献，
  只有体育专业成员有权核定，且很多在我国学生群体上**根本没有权威数值**，
  需要依据国标口径 + 实测核定。
- **工程默认值**（滤波窗口、可见性门控）是工程师的技术选择，与体育无关。

两者混在一起是这类项目最典型的质量事故：一个学生随手填的 90° 会被当成
「国家标准要求下蹲到 90 度」写进答辩材料。因此本模块用 ``source_type``
把来源钉死，并且规定 **``pending_review`` 的阈值不得驱动扣分** ——
它只能驱动「提示」。这不是形式主义，是把「我们不知道」这个事实诚实地
传递给用户，而不是编一个数字糊过去。
"""

from __future__ import annotations

import json
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from types import MappingProxyType


class SourceType(StrEnum):
    """阈值来源。取值不可随意扩展 —— 新增来源必须同步更新核定流程。

    继承 ``StrEnum``（而非 ``(str, Enum)``）是刻意的：这样 ``SourceType.X == "x"``
    成立，阈值表从 JSON 反序列化、跨模块传参、写进决策请求的 ``thresholds_version``
    审计字段时都不会因为类型不匹配而静默失配。
    """

    NATIONAL_STANDARD = "national_standard"
    """《国家学生体质健康标准》及配套测试方法。正式测量场景以此为准。"""

    LITERATURE = "literature"
    """运动科学/生物力学/临床指南文献。训练场景以此为准。"""

    PENDING_REVIEW = "pending_review"
    """尚无可靠来源，待体育专业成员核定。**不得驱动扣分。**"""


class ThresholdError(LookupError):
    """阈值不存在或不可用于当前用途。"""


@dataclass(frozen=True, slots=True)
class Threshold:
    """一条阈值。

    Attributes:
        key: 全局唯一键，规则层通过它引用阈值（而非直接写数值）。
        severity_breakpoints: 严重度分档切点，升序。空元组表示不分档。
    """

    key: str
    action_code: str
    feature_code: str
    value: float
    unit: str
    source_type: SourceType
    version: str
    standard_group: str | None = None
    sex: str | None = None
    age_min: int | None = None
    age_max: int | None = None
    severity_breakpoints: tuple[float, ...] = ()
    source_url: str | None = None
    reviewer: str | None = None
    reviewed_at: str | None = None

    @property
    def may_drive_scoring(self) -> bool:
        """本条阈值能否驱动扣分。未核定的只能驱动提示。"""
        return self.source_type is not SourceType.PENDING_REVIEW

    @property
    def provenance(self) -> str:
        """人类可读的来源描述，用于报告与答辩材料。"""
        if self.source_type is SourceType.PENDING_REVIEW:
            return "待体育专业核定"
        label = {
            SourceType.NATIONAL_STANDARD: "国家学生体质健康标准",
            SourceType.LITERATURE: "运动科学文献",
        }[self.source_type]
        return f"{label}（{self.source_url}）" if self.source_url else label


class ThresholdTable:
    """阈值表。规则层的唯一数值来源。

    典型用法::

        table = ThresholdTable.from_json(path)
        t = table.require_scorable("squat.min_depth_knee_angle")
        # ↑ 若该阈值仍是 pending_review，这里会抛异常，
        #   逼迫调用方显式选择「只出提示」的路径。
    """

    def __init__(self, thresholds: Iterable[Threshold], *, version: str) -> None:
        table: dict[str, Threshold] = {}
        for t in thresholds:
            if t.key in table:
                raise ThresholdError(f"阈值键重复：{t.key}")
            table[t.key] = t
        self._table: Mapping[str, Threshold] = MappingProxyType(table)
        self._version = version

    @property
    def version(self) -> str:
        """阈值表版本号。**必须随每次决策请求一起传给决策层**（审计要求）。"""
        return self._version

    def __len__(self) -> int:
        return len(self._table)

    def __contains__(self, key: object) -> bool:
        return key in self._table

    def get(self, key: str) -> Threshold:
        try:
            return self._table[key]
        except KeyError as exc:
            raise ThresholdError(f"阈值不存在：{key}") from exc

    def value(self, key: str) -> float:
        return self.get(key).value

    def require_scorable(self, key: str) -> Threshold:
        """取阈值并要求它可用于扣分。

        Raises:
            ThresholdError: 阈值不存在，或仍是 ``pending_review``。
        """
        t = self.get(key)
        if not t.may_drive_scoring:
            raise ThresholdError(
                f"阈值 {key} 尚未经体育专业成员核定，只能用于提示、不能驱动扣分。"
                f"若确实要出提示，请改用 get() 并显式处理 pending_review 情形。"
            )
        return t

    def for_action(self, action_code: str) -> tuple[Threshold, ...]:
        return tuple(t for t in self._table.values() if t.action_code == action_code)

    def pending_review(self) -> tuple[Threshold, ...]:
        """全部待核定阈值。交付给体育专业成员时直接导出这一份。"""
        return tuple(
            t for t in self._table.values() if t.source_type is SourceType.PENDING_REVIEW
        )

    @classmethod
    def from_json(cls, path: str | Path) -> ThresholdTable:
        """从 JSON 加载。

        文件结构::

            {
              "version": "thr_2026-10_v1",
              "thresholds": [
                {
                  "key": "squat.min_depth_knee_angle",
                  "action_code": "SQUAT",
                  "feature_code": "knee_angle_L",
                  "value": 95.0,
                  "unit": "deg",
                  "source_type": "pending_review",
                  "source_url": null,
                  "severity_breakpoints": []
                }
              ]
            }
        """
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        required = {"version", "thresholds"}
        missing = required - raw.keys()
        if missing:
            raise ThresholdError(f"阈值文件缺少字段：{sorted(missing)}")

        items = []
        for entry in raw["thresholds"]:
            try:
                items.append(
                    Threshold(
                        key=entry["key"],
                        action_code=entry["action_code"],
                        feature_code=entry["feature_code"],
                        value=float(entry["value"]),
                        unit=entry["unit"],
                        source_type=SourceType(entry["source_type"]),
                        version=raw["version"],
                        standard_group=entry.get("standard_group"),
                        sex=entry.get("sex"),
                        age_min=entry.get("age_min"),
                        age_max=entry.get("age_max"),
                        severity_breakpoints=tuple(entry.get("severity_breakpoints", ())),
                        source_url=entry.get("source_url"),
                        reviewer=entry.get("reviewer"),
                        reviewed_at=entry.get("reviewed_at"),
                    )
                )
            except KeyError as exc:
                raise ThresholdError(f"阈值条目缺少字段 {exc}：{entry!r}") from exc
        return cls(items, version=raw["version"])


__all__ = ["SourceType", "Threshold", "ThresholdError", "ThresholdTable"]
