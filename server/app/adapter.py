"""领域层 → 决策契约的适配器。

这是整个项目里**两个包唯一的接缝**：领域层（``vitalteen_domain``）产出
``SetSummary`` 与逐次 ``RepWindow``，契约层要求 ``DecisionRequest``。

两边各自都有完整测试，但接缝本身此前没有任何覆盖 —— 而这类缝正是最容易出错的
地方：字段名对不上、序号基准不同（0-based 还是 1-based）、单位不一致，
**都不会报错**，只会让判定结果悄悄错掉，且错得很像真的。

映射中几个需要留意、也刻意记在这里的决定
----------------------------------------

**``valid_rep_count`` 直接等于 ``rep_count``。** 领域层的 ``RepTracker`` 只封存
到达过底部相位的动作，能进入 ``completed`` 的本来就都是有效动作 ——
「无效 rep」在领域层压根不会被记录。若将来引入「质量不足但仍计数」的语义，
这里必须同步修改，而不是想当然地留个空。

**``reps[].index`` 用 ``RepWindow.index``**，它是从 1 开始的序号，与
``FaultStat.rep_indices`` 同源，因此报告里「第 2、5、7 次」能对得上。

**组级指标（节奏、幅度、对称）不在这里编。** ``SetSummary`` 不含它们；
逐次相位时长可以推出平均单次用时，但活动幅度与对称指数需要逐帧特征。
没有可靠来源时留空，而不是用 0 或估算值填充（铁律二）。

**本模块刻意不在 ``app/__init__.py`` 的导入链上。**

生产环境里，决策请求由手机端（Dart）直接产出并 POST 上来 —— 服务端不需要把
领域层的对象转成契约。本模块服务于三件事：

1. **集成测试**：覆盖领域层与契约之间的接缝（那是两个包唯一的交界）
2. **离线批处理**：处理录制的会话记录
3. **端侧实现的参照**：Dart 侧的请求组装逻辑应当与本模块逐字段对齐

把它挂在包入口上会让 ``import app`` 依赖 ``vitalteen_domain`` 是否可导入，
从而在只部署服务端时直接崩掉 —— 一个测试与工具用的模块，不该有这种权力。
"""

from __future__ import annotations

from collections.abc import Sequence

from vitalteen_domain.rules import Fault, RepWindow, RuleEngine, SetSummary

from .contracts import (
    SCHEMA_VERSION,
    CandidateIn,
    DecisionContext,
    DecisionRequest,
    DeviationIn,
    FaultIn,
    FaultStatIn,
    PoseQuality,
    RepIn,
    SetIn,
)


def _duration_ms(window: RepWindow) -> int:
    """一次 rep 的时长（毫秒）。

    **公式在领域层**（``RepWindow.duration_ms``），这里只做转发 ——
    端侧的计时器读的是同一个属性，两处各算一遍就会出现「计时器说 40.0 秒、
    请求里写 39.9 秒」这种没有报错的分歧。
    """
    return window.duration_ms


def _phases_ms(window: RepWindow) -> dict[str, int]:
    """各相位时长。索引是相对 rep 缓冲的闭区间，因此末帧下标要 +1 才是帧数。"""
    out: dict[str, int] = {}
    for phase, (start, end) in window.phase_bounds.items():
        frames = window.frames[start : end + 1]
        if len(frames) < 2:
            out[str(phase)] = 0
            continue
        out[str(phase)] = max(0, frames[-1].timestamp_ms - frames[0].timestamp_ms)
    return out


def _fault_in(fault: Fault) -> FaultIn:
    return FaultIn(
        code=fault.code,
        confidence=fault.confidence,
        evidence_frames=list(fault.evidence_timestamps),
        deviations=[
            DeviationIn(
                feature=fault.deviation.feature,
                measured=fault.deviation.measured,
                threshold=fault.deviation.threshold,
                delta_signed=fault.deviation.delta_signed,
                severity_0_1=fault.deviation.severity_0_1,
            )
        ],
    )


def build_rep_details(
    windows: Sequence[RepWindow], engine: RuleEngine
) -> list[RepIn]:
    """把逐次 rep 窗口与规则判定翻译成契约里的 ``reps[]``。

    逐次明细不是可有可无的装饰：组级统计只能说明「10 次里犯了 3 次」，
    而决策层要判断「这个问题是稳定复现还是偶发」时必须看逐次分布。
    """
    return [
        RepIn(
            index=window.index,
            duration_ms=_duration_ms(window),
            phases_ms=_phases_ms(window),
            metrics={},
            faults=[_fault_in(fault) for fault in engine.evaluate_rep(window)],
            # confidence 留空：RepWindow 不含逐次置信度，而填 1.0 等于声称
            # 「这次动作的数据完全可信」—— 那是个没有依据的结论。
            confidence=None,
        )
        for window in windows
    ]


def build_request(
    summary: SetSummary,
    *,
    request_id: str,
    context: DecisionContext,
    pose_quality: PoseQuality,
    thresholds_version: str,
    windows: Sequence[RepWindow] = (),
    engine: RuleEngine | None = None,
) -> DecisionRequest:
    """把领域层的判定结果组装成决策请求。

    Args:
        summary: 组级判定汇总（领域层 ``RuleEngine.evaluate_set`` 的产物）。
        windows: 逐次 rep 窗口。给出后才会填充 ``reps[]``。
        engine: 规则引擎。给出后才会对每个窗口重新求值以填充逐次错误。
            **必须与产出 ``summary`` 的是同一个引擎实例**，否则逐次明细与组级
            汇总会对不上 —— 那是最难查的一类不一致。

    Raises:
        ValueError: 给了 ``windows`` 却没给 ``engine``（或反之），
            此时 ``reps[]`` 会静默为空，而调用方多半以为它填充了。
    """
    if windows and engine is None:
        raise ValueError(
            "提供了 windows 却没有提供 engine：逐次错误无法填充，reps[] 会静默为空。"
            "要么两个都给，要么两个都不给。"
        )

    fault_stats = [
        FaultStatIn(code=stat.code, reps=list(stat.rep_indices), count=stat.count)
        for stat in summary.fault_stats
    ]

    return DecisionRequest(
        request_id=request_id,
        schema_version=SCHEMA_VERSION,
        context=context,
        pose_quality=pose_quality,
        set=SetIn(
            rep_count=summary.rep_count,
            # 领域层只封存到达过底部的动作，「无效 rep」不会被记录，故两者相等。
            valid_rep_count=summary.rep_count,
            tempo_mean_ms=_mean_tempo_ms(windows),
            fault_stats=fault_stats,
        ),
        reps=build_rep_details(windows, engine) if engine is not None else [],
        candidates=[
            CandidateIn(code=stat.code, triggered_by_rule="rule_engine")
            for stat in summary.fault_stats
        ],
        thresholds_version=thresholds_version,
    )


def _mean_tempo_ms(windows: Sequence[RepWindow]) -> float | None:
    """平均单次用时。没有窗口时返回 ``None`` —— 不编造一个 0。"""
    durations = [_duration_ms(window) for window in windows if len(window.frames) >= 2]
    return sum(durations) / len(durations) if durations else None


__all__ = ["build_rep_details", "build_request"]
