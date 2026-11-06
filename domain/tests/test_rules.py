"""``vitalteen_domain.rules`` 错误规则引擎测试。

锁死的约定（docs/domain-layer-design.md §5、§7）：

- 判定模型统一为「指定相位窗口内，越界帧数达到下限即命中」：恰好等于
  ``min_violating_frames`` 命中（门槛是 ``>=`` 而非 ``>``），少一帧判为噪声；
- 相位窗口是闭区间；``Phase.ALL`` 与相位表中缺失的相位都退化为整段 ——
  「下蹲深度不足」这类规则没有独立逻辑，靠只在 ``BOTTOM`` 相位求值归位；
- 阈值 ``source_type=pending_review`` 时规则照常判定，但产出的 ``Fault``
  必须 ``scorable=False``（只出提示、不计扣分）；已核定的必须 ``scorable=True``；
- 置信度 = 越界帧占比 × 有效帧占比；部分帧特征不可用必须由 validity 因子降权；
- 组级 ``rate`` 的分母是 rep 总数，同一 rep 内重复命中同一错误码只计一次；
- 不可用数据（特征缺失/不可用、空窗口）返回空元组，绝不抛异常、绝不填 0。

参数校验：``Rule`` 在构造期拒绝 ``min_violating_frames < 1`` 与 ``severity_span <= 0``。
这两条曾是标记为 xfail 的实现缺陷，现已在 ``Rule.__post_init__`` 中修复 ——
这类错误应在定义动作时立刻暴露，而不是等运行到某个特定数据组合上才以
``ValueError`` 的形式炸开（见 ``TestRuleValidation``）。

测试数据全部由顶部工厂函数构造；阈值表用 ``ThresholdTable([...], version=...)``
直接构造，不依赖 ``shared/thresholds/*.json``（真实表全为 ``pending_review``，
无法覆盖「已核定」分支，也无法自由控制来源类型）。
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import FrozenInstanceError
from types import MappingProxyType

import pytest

from vitalteen_domain.features import FeatureValue, FrameFeatures
from vitalteen_domain.rules import (
    REVERSAL_DEADBAND,
    Direction,
    Phase,
    Reduce,
    RepWindow,
    Rule,
    RuleEngine,
    count_reversals,
)
from vitalteen_domain.thresholds import (
    SourceType,
    Threshold,
    ThresholdError,
    ThresholdTable,
)

# ---------------------------------------------------------------------------
# 常量与辅助工厂
# ---------------------------------------------------------------------------

FRAME_MS = 33  # 与 30fps 采集对齐（同 test_state_machine）
TEST_TABLE_VERSION = "test_v1"

DEFAULT_METRIC = "knee_angle_L"
DEFAULT_UNIT = "deg"
DEFAULT_THRESHOLD_KEY = "test.knee_angle_min"
DEFAULT_THRESHOLD_VALUE = 100.0


def make_frame(timestamp_ms: int, **values: float | None) -> FrameFeatures:
    """构造一帧。``values`` 里 ``None`` 表示该特征不可用（如低可见性）。

    未列出的特征码在该帧中直接缺席 —— 对规则引擎来说与不可用等价，都必须跳过。
    """
    stored = {
        code: (
            FeatureValue.unavailable(code, DEFAULT_UNIT, "pixel", "low_visibility")
            if value is None
            else FeatureValue(
                code=code,
                value=value,
                unit=DEFAULT_UNIT,
                coord_space="pixel",
                valid=True,
            )
        )
        for code, value in values.items()
    }
    return FrameFeatures(timestamp_ms=timestamp_ms, values=MappingProxyType(stored))


def make_frames(
    values: Sequence[float | None],
    *,
    code: str = DEFAULT_METRIC,
    start_ms: int = 0,
    step_ms: int = FRAME_MS,
) -> tuple[FrameFeatures, ...]:
    """把单一特征的取值序列包装成帧序列，时间戳按 ``step_ms`` 递增。"""
    return tuple(
        make_frame(start_ms + index * step_ms, **{code: value})
        for index, value in enumerate(values)
    )


def make_window(
    frames: Sequence[FrameFeatures],
    *,
    index: int = 0,
    phase_bounds: Mapping[Phase, tuple[int, int]] | None = None,
) -> RepWindow:
    """构造 rep 窗口；``phase_bounds`` 缺省 = 无相位切分（一切相位退化为整段）。"""
    if phase_bounds is None:
        return RepWindow(index=index, frames=tuple(frames))
    return RepWindow(
        index=index,
        frames=tuple(frames),
        phase_bounds=MappingProxyType(dict(phase_bounds)),
    )


def make_threshold(
    key: str = DEFAULT_THRESHOLD_KEY,
    *,
    value: float = DEFAULT_THRESHOLD_VALUE,
    source_type: SourceType = SourceType.NATIONAL_STANDARD,
    feature_code: str = DEFAULT_METRIC,
    unit: str = DEFAULT_UNIT,
    action_code: str = "TEST",
) -> Threshold:
    """构造一条测试阈值；默认已核定（可驱动扣分），治理测试自行覆盖来源类型。"""
    return Threshold(
        key=key,
        action_code=action_code,
        feature_code=feature_code,
        value=value,
        unit=unit,
        source_type=source_type,
        version=TEST_TABLE_VERSION,
    )


def make_table(*thresholds: Threshold, version: str = TEST_TABLE_VERSION) -> ThresholdTable:
    """构造阈值表。测试一律显式传入阈值，不读取 shared/thresholds 下的真实表。"""
    return ThresholdTable(thresholds, version=version)


def make_rule(
    *,
    code: str = "TEST_FAULT",
    name_zh: str = "测试错误",
    metric: str = DEFAULT_METRIC,
    threshold_key: str = DEFAULT_THRESHOLD_KEY,
    bad_side: Direction = Direction.BELOW,
    phase: Phase = Phase.ALL,
    use_abs: bool = False,
    min_violating_frames: int = 3,
    severity_span: float | None = None,
) -> Rule:
    """构造一条规则；缺省语义：膝角低于 100° 累计 3 帧即命中。"""
    return Rule(
        code=code,
        name_zh=name_zh,
        metric=metric,
        threshold_key=threshold_key,
        bad_side=bad_side,
        phase=phase,
        use_abs=use_abs,
        min_violating_frames=min_violating_frames,
        severity_span=severity_span,
    )


def make_engine(
    rules: Sequence[Rule],
    *,
    thresholds: ThresholdTable | None = None,
) -> RuleEngine:
    """构造引擎；未指定阈值表时使用与缺省规则配套的已核定阈值表。"""
    if thresholds is None:
        thresholds = make_table(make_threshold())
    return RuleEngine(rules, thresholds)


# ---------------------------------------------------------------------------
# 组级聚合场景：设计文档 §5.2 的 ASYMMETRY 由两个特征共同判定同一错误码
# ---------------------------------------------------------------------------


def _asymmetry_engine() -> RuleEngine:
    """同一错误码挂两条规则（knee_symmetry 与 pelvis_offset_ratio 各判一次）。"""
    rules = [
        make_rule(
            code="ASYMMETRY",
            name_zh="左右不对称",
            metric="knee_symmetry",
            threshold_key="test.knee_symmetry_max",
            bad_side=Direction.ABOVE,
        ),
        make_rule(
            code="ASYMMETRY",
            name_zh="左右不对称",
            metric="pelvis_offset_ratio",
            threshold_key="test.pelvis_offset_max",
            bad_side=Direction.ABOVE,
        ),
    ]
    thresholds = make_table(
        make_threshold(
            "test.knee_symmetry_max", value=0.05, unit="ratio", feature_code="knee_symmetry"
        ),
        make_threshold(
            "test.pelvis_offset_max",
            value=0.10,
            unit="ratio",
            feature_code="pelvis_offset_ratio",
        ),
    )
    return RuleEngine(rules, thresholds)


def _asymmetry_windows() -> tuple[RepWindow, ...]:
    """三个 rep：rep0 两特征同时越界，rep1 仅 knee_symmetry 越界，rep2 全部达标。"""
    return (
        make_window(
            (
                make_frame(0, knee_symmetry=0.10, pelvis_offset_ratio=0.20),
                make_frame(FRAME_MS, knee_symmetry=0.12, pelvis_offset_ratio=0.15),
                make_frame(2 * FRAME_MS, knee_symmetry=0.11, pelvis_offset_ratio=0.21),
            ),
            index=0,
        ),
        make_window(
            (
                make_frame(0, knee_symmetry=0.06, pelvis_offset_ratio=0.01),
                make_frame(FRAME_MS, knee_symmetry=0.07, pelvis_offset_ratio=0.02),
                make_frame(2 * FRAME_MS, knee_symmetry=0.08, pelvis_offset_ratio=0.03),
            ),
            index=1,
        ),
        make_window(
            (
                make_frame(0, knee_symmetry=0.01, pelvis_offset_ratio=0.02),
                make_frame(FRAME_MS, knee_symmetry=0.02, pelvis_offset_ratio=0.03),
                make_frame(2 * FRAME_MS, knee_symmetry=0.01, pelvis_offset_ratio=0.02),
            ),
            index=2,
        ),
    )


# ---------------------------------------------------------------------------
# 相位窗口选择
# ---------------------------------------------------------------------------


class TestRepWindowPhaseSelection:
    """``RepWindow.select`` 的窗口语义：闭区间、ALL 与缺失相位都退化整段。"""

    def test_all_phase_returns_every_frame(self) -> None:
        window = make_window(make_frames([1.0, 2.0, 3.0]), phase_bounds={Phase.BOTTOM: (1, 1)})
        assert window.select(Phase.ALL) == window.frames

    def test_missing_phase_falls_back_to_whole_rep(self) -> None:
        # 相位表里没有 DESCENT（例如切分未提供该相位）：退化为整段，而不是空窗。
        window = make_window(make_frames([1.0, 2.0, 3.0]), phase_bounds={Phase.BOTTOM: (1, 1)})
        assert window.select(Phase.DESCENT) == window.frames

    def test_phase_bounds_are_inclusive_on_both_ends(self) -> None:
        frames = make_frames([10.0, 20.0, 30.0, 40.0, 50.0, 60.0])
        window = make_window(frames, phase_bounds={Phase.BOTTOM: (1, 3)})
        selected = window.select(Phase.BOTTOM)
        assert selected == (frames[1], frames[2], frames[3])
        assert tuple(frame.timestamp_ms for frame in selected) == (
            FRAME_MS,
            2 * FRAME_MS,
            3 * FRAME_MS,
        )

    def test_negative_start_is_clamped_to_zero(self) -> None:
        frames = make_frames([10.0, 20.0, 30.0, 40.0])
        window = make_window(frames, phase_bounds={Phase.DESCENT: (-5, 1)})
        assert window.select(Phase.DESCENT) == (frames[0], frames[1])

    def test_end_beyond_last_index_is_clamped_by_slicing(self) -> None:
        frames = make_frames([10.0, 20.0, 30.0, 40.0])
        window = make_window(frames, phase_bounds={Phase.ASCENT: (3, 99)})
        assert window.select(Phase.ASCENT) == (frames[3],)


# ---------------------------------------------------------------------------
# 越界计数：min_violating_frames 的门槛作用
# ---------------------------------------------------------------------------


class TestViolatingFrameCount:
    """越界帧数下限：``len(violating) < min_violating_frames`` 才判噪声，等于下限即命中。"""

    def test_two_violations_below_default_min_is_noise(self) -> None:
        # 默认 min_violating_frames=3：60 帧窗口里 2 帧越界视为抖动，不产出错误。
        window = make_window(make_frames([98.0, 97.0, 105.0, 100.0, 101.0]))
        assert make_engine([make_rule()]).evaluate_rep(window) == ()

    def test_exactly_min_violating_frames_hits(self) -> None:
        # 门槛语义是 `len(violating) >= min`：恰好 3 帧必须命中，不得用 > 卡掉。
        window = make_window(make_frames([98.0, 97.0, 96.0, 100.0, 105.0]))
        (fault,) = make_engine([make_rule()]).evaluate_rep(window)
        assert fault.evidence_timestamps == (0, FRAME_MS, 2 * FRAME_MS)

    def test_min_violating_frames_is_configurable_per_rule(self) -> None:
        # 显式放宽到 1 帧：单帧越界即命中——抖动容忍度是规则作者的显式选择。
        window = make_window(make_frames([98.0, 105.0, 106.0, 100.0, 101.0]))
        engine = make_engine([make_rule(min_violating_frames=1)])
        (fault,) = engine.evaluate_rep(window)
        assert fault.deviation.measured == pytest.approx(98.0)

    @pytest.mark.parametrize(
        "bad_side", [Direction.ABOVE, Direction.BELOW], ids=["above", "below"]
    )
    def test_value_equal_to_threshold_is_not_a_violation(self, bad_side: Direction) -> None:
        # 比较是严格不等式：恰好等于阈值（100.0）不算越界，两个方向一致。
        window = make_window(make_frames([100.0, 100.0, 100.0]))
        assert make_engine([make_rule(bad_side=bad_side)]).evaluate_rep(window) == ()


# ---------------------------------------------------------------------------
# bad_side：两个方向各自的判定
# ---------------------------------------------------------------------------


class TestDirection:
    """ABOVE 只数严格大于阈值的帧，BELOW 只数严格小于阈值的帧。"""

    def test_above_side_counts_only_values_above_threshold(self) -> None:
        rule = make_rule(bad_side=Direction.ABOVE)
        window = make_window(make_frames([103.0, 101.0, 100.0, 102.0, 99.0]))
        (fault,) = make_engine([rule]).evaluate_rep(window)
        # 越界帧：103/101/102（等于 100 的帧不算）；最坏值是最大值 103。
        assert fault.evidence_timestamps == (0, FRAME_MS, 3 * FRAME_MS)
        assert fault.deviation.measured == pytest.approx(103.0)
        assert fault.deviation.delta_signed == pytest.approx(3.0)

    def test_below_side_counts_only_values_below_threshold(self) -> None:
        rule = make_rule(bad_side=Direction.BELOW)
        window = make_window(make_frames([97.0, 99.0, 100.0, 98.0, 101.0]))
        (fault,) = make_engine([rule]).evaluate_rep(window)
        assert fault.evidence_timestamps == (0, FRAME_MS, 3 * FRAME_MS)
        assert fault.deviation.measured == pytest.approx(97.0)
        # BELOW 方向的偏离带负号：measured - threshold = -3。
        assert fault.deviation.delta_signed == pytest.approx(-3.0)


# ---------------------------------------------------------------------------
# use_abs：带符号量先取绝对值
# ---------------------------------------------------------------------------


class TestUseAbs:
    """``use_abs`` 服务于躯干前倾这类符号取决于面朝方向的量，比较前先取绝对值。"""

    def test_signed_value_is_compared_by_magnitude(self) -> None:
        rule = make_rule(
            metric="trunk_lean",
            threshold_key="test.trunk_lean_max",
            bad_side=Direction.ABOVE,
            use_abs=True,
        )
        thresholds = make_table(
            make_threshold("test.trunk_lean_max", value=20.0, feature_code="trunk_lean")
        )
        window = make_window(make_frames([-25.0, -22.0, -21.0, 15.0, 5.0], code="trunk_lean"))
        (fault,) = RuleEngine([rule], thresholds).evaluate_rep(window)
        # |-25| > 20 命中；measured 报告绝对值后的最坏值 25 而非 -25。
        assert fault.deviation.measured == pytest.approx(25.0)
        assert fault.deviation.delta_signed == pytest.approx(5.0)

    def test_without_use_abs_negative_values_slip_under_above_rule(self) -> None:
        # 对照实验：同一序列、同样的 ABOVE 阈值 20，不取绝对值时画面另一侧的
        # 前倾（负值）全部漏过 —— 这正是 use_abs 存在的理由。
        rule = make_rule(
            metric="trunk_lean",
            threshold_key="test.trunk_lean_max",
            bad_side=Direction.ABOVE,
            use_abs=False,
        )
        thresholds = make_table(
            make_threshold("test.trunk_lean_max", value=20.0, feature_code="trunk_lean")
        )
        window = make_window(make_frames([-25.0, -22.0, -21.0, 15.0, 5.0], code="trunk_lean"))
        assert RuleEngine([rule], thresholds).evaluate_rep(window) == ()

    def test_use_abs_with_below_side_flags_near_zero_magnitude(self) -> None:
        # use_abs 在 BELOW 方向的含义：绝对值过小（接近 0）即越界。
        rule = make_rule(bad_side=Direction.BELOW, use_abs=True)
        window = make_window(make_frames([95.0, -3.0, 2.0, -1.0, 110.0]))
        (fault,) = make_engine([rule]).evaluate_rep(window)
        # |±小值| < 100 的 3 帧命中；最坏值是绝对值里的最小值 1.0。
        assert fault.deviation.measured == pytest.approx(1.0)


# ---------------------------------------------------------------------------
# 弹振：REVERSALS 看的是序列的形状，不是任何一个极值
# ---------------------------------------------------------------------------


_REACH_DOWN = [90.0 - 3 * i for i in range(17)]
"""前伸：90°（坐直）匀速降到 42°（前伸到底）。"""

_REACH_UP = [45.0 + 3 * i for i in range(16)]
"""坐回：45° 匀速升回 90°。起点错开一格，免得与下降段首尾重合成 0 步。"""

_REACH_DOWN_AGAIN = [87.0 - 3 * i for i in range(16)]
"""弹振的后续几趟：从 87°（不是 90°）再降回 42°。"""


def _smooth_reach() -> list[float]:
    """匀速前伸：下去再上来，**掉头一次**。"""
    return _REACH_DOWN + _REACH_UP


def _ballistic_reach() -> list[float]:
    """弹振前伸：来回弹三趟（五段，**掉头四次**）。

    **与 :func:`_smooth_reach` 的最低点完全相同（都是 42°）** —— 这正是这条
    判据存在的理由：弹的那一下够得一点不比慢慢来的近。
    """
    return _REACH_DOWN + _REACH_UP + _REACH_DOWN_AGAIN + _REACH_UP + _REACH_DOWN_AGAIN


class TestReversals:
    """``Reduce.REVERSALS`` 与 :func:`count_reversals`。

    前四个归约都是「挑一个代表值再比阈值」，弹振不是这么坏的：靠弹振够距离的人
    前伸到底那一刻的角度可能是够的，坏的是过程。证据是序列的形状。
    """

    def test_smooth_reach_turns_once_and_ballistic_turns_four_times(self) -> None:
        assert count_reversals(_smooth_reach()) == 1
        assert count_reversals(_ballistic_reach()) == 4
        # 两者的最低点必须相同 —— 少了它，这条判据拿「够不够远」就能分开两个人。
        assert min(_smooth_reach()) == min(_ballistic_reach())

    def test_deadband_swallows_sensor_jitter(self) -> None:
        """匀速前伸叠上读数抖动，死区之内不算掉头。

        **这一条是这条判据能不能用的分界。** 关掉死区，同一段匀速前伸会被数成
        上百次掉头 —— 那样躺平的人也会被判「弹振借力」。
        """
        jittered = [90.0 - i * 0.6 + (0.9 if i % 2 == 0 else -0.9) for i in range(200)]

        assert count_reversals(jittered) == 0
        assert count_reversals(jittered, deadband=0) > 100
        assert REVERSAL_DEADBAND == 2.0  # 与 Dart 侧逐字一致

    def test_deadband_boundary(self) -> None:
        # 摆幅 4°（> 2°）算；摆幅 1°（< 2°）不算。五次采样是四步，
        # 头一步只用来定方向 —— 所以 50↔54 来回得到的是 3 次。
        assert count_reversals([50.0, 54.0, 50.0, 54.0, 50.0]) == 3
        assert count_reversals([50.0, 51.0, 50.0, 51.0, 50.0]) == 0

    def test_short_sequences_do_not_turn(self) -> None:
        assert count_reversals([]) == 0
        assert count_reversals([50.0]) == 0
        assert count_reversals([50.0, 45.0]) == 0
        assert count_reversals([50.0, 45.0, 40.0]) == 0

    def test_engine_wires_reversals_through(self) -> None:
        # 直接测 count_reversals 只证明这个函数对；这一条证明它接进了引擎。
        # 窗口取 Phase.ALL：弹振的证据散在整次动作上。
        rule = Rule(
            code="SRT_BALLISTIC",
            name_zh="弹振借力",
            metric="hip_angle_L",
            threshold_key="srt.ballistic_reversals_max",
            bad_side=Direction.ABOVE,
            phase=Phase.ALL,
            reduce=Reduce.REVERSALS,
            severity_span=4.0,
        )
        thresholds = make_table(
            make_threshold(
                "srt.ballistic_reversals_max", value=3.0, feature_code="hip_angle_L"
            )
        )
        engine = RuleEngine([rule], thresholds)

        def window_of(values: list[float]) -> RepWindow:
            return make_window(
                make_frames(values, code="hip_angle_L"),
                phase_bounds={Phase.BOTTOM: (0, len(values) - 1)},
            )

        assert engine.evaluate_rep(window_of(_smooth_reach())) == ()
        (fault,) = engine.evaluate_rep(window_of(_ballistic_reach()))
        assert fault.code == "SRT_BALLISTIC"
        assert fault.deviation.measured == pytest.approx(4.0)


# ---------------------------------------------------------------------------
# 相位窗口：规则只在声明的相位内求值
# ---------------------------------------------------------------------------


class TestPhaseScoping:
    """「下蹲深度不足」没有独立逻辑，靠只在 BOTTOM 相位求值归位。"""

    def test_insufficient_depth_rule_sees_only_its_phase(self) -> None:
        # 规则语义：BOTTOM 相位内膝角累计 3 帧高于深度线 100°（bad_side=ABOVE）
        # → 蹲得不够深。底部足够深时，其它相位站直段的越界帧不得算入。
        rule = make_rule(
            code="INSUFFICIENT_DEPTH",
            name_zh="下蹲深度不足",
            bad_side=Direction.ABOVE,
            phase=Phase.BOTTOM,
        )
        engine = make_engine([rule])
        shallow_bottom = make_window(
            make_frames([90.0, 95.0, 120.0, 125.0, 130.0, 92.0]),
            index=0,
            phase_bounds={Phase.BOTTOM: (2, 4)},
        )
        deep_bottom = make_window(
            make_frames([120.0, 125.0, 130.0, 90.0, 95.0, 92.0]),
            index=1,
            phase_bounds={Phase.BOTTOM: (3, 5)},
        )

        (fault,) = engine.evaluate_rep(shallow_bottom)
        assert fault.code == "INSUFFICIENT_DEPTH"
        assert fault.deviation.measured == pytest.approx(130.0)
        assert engine.evaluate_rep(deep_bottom) == ()

    def test_same_rule_without_phase_scoping_hits_frames_outside_bottom(self) -> None:
        # 对照：放宽到 ALL 后，deep_bottom 里站直段的越界帧立刻把规则命中 ——
        # 命中与否完全由相位窗口决定，而不是规则里的额外逻辑。
        rule = make_rule(bad_side=Direction.ABOVE, phase=Phase.ALL)
        window = make_window(
            make_frames([120.0, 125.0, 130.0, 90.0, 95.0, 92.0]),
            phase_bounds={Phase.BOTTOM: (3, 5)},
        )
        (fault,) = make_engine([rule]).evaluate_rep(window)
        assert fault.deviation.measured == pytest.approx(130.0)

    def test_missing_phase_bounds_falls_back_to_whole_rep(self) -> None:
        # 相位表缺失该相位时退化为整段：宁可全段保守求值，也不静默变成永不命中。
        rule = make_rule(bad_side=Direction.ABOVE, phase=Phase.BOTTOM)
        window = make_window(make_frames([120.0, 125.0, 130.0, 90.0, 95.0, 92.0]))
        assert len(make_engine([rule]).evaluate_rep(window)) == 1


# ---------------------------------------------------------------------------
# deviation：最坏值、带符号偏离、严重度归一
# ---------------------------------------------------------------------------


class TestDeviationReporting:
    """偏离量报告最坏情况（越界方向上的极值），不是均值、不是最后一帧。"""

    def test_measured_reports_worst_value_not_mean_or_last(self) -> None:
        window = make_window(make_frames([80.0, 99.0, 98.0, 120.0, 130.0]))
        (fault,) = make_engine([make_rule()]).evaluate_rep(window)
        # BELOW 方向最坏值是最小值 80（越界帧均值 92.33、末帧 130 都不是）。
        assert fault.deviation.measured == pytest.approx(80.0)
        assert fault.deviation.delta_signed == pytest.approx(-20.0)
        assert fault.deviation.threshold == pytest.approx(DEFAULT_THRESHOLD_VALUE)

    def test_measured_reports_maximum_for_above_rules(self) -> None:
        rule = make_rule(bad_side=Direction.ABOVE)
        window = make_window(make_frames([105.0, 121.0, 110.0, 90.0, 95.0]))
        (fault,) = make_engine([rule]).evaluate_rep(window)
        assert fault.deviation.measured == pytest.approx(121.0)
        assert fault.deviation.delta_signed == pytest.approx(21.0)

    def test_severity_is_none_when_span_is_absent(self) -> None:
        fault = make_engine([make_rule(severity_span=None)]).evaluate_rep(
            make_window(make_frames([80.0, 85.0, 90.0]))
        )[0]
        assert fault.deviation.severity_0_1 is None

    def test_severity_normalizes_delta_by_span(self) -> None:
        # 偏离 -20°，span=40 → 0.5。
        fault = make_engine([make_rule(severity_span=40.0)]).evaluate_rep(
            make_window(make_frames([80.0, 85.0, 90.0]))
        )[0]
        assert fault.deviation.severity_0_1 == pytest.approx(0.5)

    def test_severity_is_capped_at_one(self) -> None:
        # 偏离 -20°，span=10 → 名义值 2.0 必须截到 1.0（契约是 0–1）。
        fault = make_engine([make_rule(severity_span=10.0)]).evaluate_rep(
            make_window(make_frames([80.0, 85.0, 90.0]))
        )[0]
        assert fault.deviation.severity_0_1 == pytest.approx(1.0)

    def test_zero_severity_span_is_rejected(self) -> None:
        # span 是「超出多少算满严重度」的归一化基准，0 没有意义（会除零）。
        # 曾用真值判断 `if rule.severity_span` 把它静默当成「不归一」，现在构造期即拒绝。
        with pytest.raises(ValueError, match="severity_span"):
            make_rule(severity_span=0.0)


# ---------------------------------------------------------------------------
# 置信度：coverage × validity
# ---------------------------------------------------------------------------


class TestConfidence:
    """置信度 = 越界帧占比 × 有效帧占比；两个因子缺一不可。"""

    def test_full_validity_confidence_equals_coverage(self) -> None:
        # coverage = 3/4（4 个可用样本里 3 帧越界），validity = 1.0。
        window = make_window(make_frames([95.0, 97.0, 105.0, 99.0]))
        (fault,) = make_engine([make_rule()]).evaluate_rep(window)
        assert fault.confidence == pytest.approx(0.75)

    def test_unavailable_frames_lower_confidence_via_validity_factor(self) -> None:
        # 同样的 3 条越界帧，但窗口里多了 2 帧特征不可用：
        # coverage 仍是 3/4（不可用帧不进分母），validity 降为 4/6，
        # 置信度从 0.75 掉到 0.5 —— 数据本身不可信时不得给高置信。
        engine = make_engine([make_rule()])
        with_unavailable = make_window(make_frames([95.0, 97.0, 105.0, 99.0, None, None]))
        control = make_window(make_frames([95.0, 97.0, 105.0, 99.0]))

        fault = engine.evaluate_rep(with_unavailable)[0]
        control_fault = engine.evaluate_rep(control)[0]

        assert fault.confidence == pytest.approx(0.5)
        assert fault.confidence < control_fault.confidence


# ---------------------------------------------------------------------------
# 不可用数据：绝不抛异常、绝不编造结论（铁律二）
# ---------------------------------------------------------------------------


class TestUnusableData:
    """特征缺失/不可用/空窗口一律返回空元组，而不是填 0 或崩溃。"""

    def test_window_with_all_frames_unavailable_returns_empty_tuple(self) -> None:
        window = make_window(make_frames([None, None, None, None]))
        assert make_engine([make_rule()]).evaluate_rep(window) == ()

    def test_metric_absent_from_frames_returns_empty_tuple(self) -> None:
        # 帧里根本没有该特征码（动作定义未声明 / 提取器未产出）。
        frames = (
            make_frame(0, hip_angle_L=90.0),
            make_frame(FRAME_MS, hip_angle_L=95.0),
        )
        assert make_engine([make_rule()]).evaluate_rep(make_window(frames)) == ()

    def test_invalid_feature_with_stale_value_is_ignored(self) -> None:
        # FeatureValue.unavailable 的 value 恒为 None，但引擎不依赖这一不变量：
        # is_valid 为 False 的值即使非 None 也必须忽略，绝不能拿来比较。
        stale = FrameFeatures(
            timestamp_ms=0,
            values=MappingProxyType(
                {
                    DEFAULT_METRIC: FeatureValue(
                        code=DEFAULT_METRIC,
                        value=80.0,
                        unit=DEFAULT_UNIT,
                        coord_space="pixel",
                        valid=False,
                        invalid_reason="low_visibility",
                    ),
                }
            ),
        )
        assert make_engine([make_rule()]).evaluate_rep(make_window((stale,))) == ()

    def test_valid_but_none_value_is_skipped_not_crashed(self) -> None:
        # valid=True 却 value=None 是矛盾状态；引擎必须跳过该帧而不是拿 None 比较。
        odd = FrameFeatures(
            timestamp_ms=0,
            values=MappingProxyType(
                {
                    DEFAULT_METRIC: FeatureValue(
                        code=DEFAULT_METRIC,
                        value=None,
                        unit=DEFAULT_UNIT,
                        coord_space="pixel",
                        valid=True,
                    ),
                }
            ),
        )
        frames = (odd, *make_frames([95.0, 96.0, 97.0], start_ms=FRAME_MS))
        (fault,) = make_engine([make_rule()]).evaluate_rep(make_window(frames))
        # 3 条可用样本全部越界；那一帧异常数据仍由 validity = 3/4 如实降权。
        assert fault.confidence == pytest.approx(0.75)

    def test_empty_frame_tuple_returns_empty_tuple(self) -> None:
        # 空窗口在选择阶段就返回空样本元组；实现里 `validity = ... if frames else 0.0`
        # 的兜底分支因此实际不可达（防御性代码），这里锁定的是不抛异常。
        window = RepWindow(index=0, frames=())
        assert window.select(Phase.ALL) == ()
        assert make_engine([make_rule()]).evaluate_rep(window) == ()


# ---------------------------------------------------------------------------
# 阈值治理：pending_review 只能出提示
# ---------------------------------------------------------------------------


class TestThresholdGovernance:
    """未核定阈值仍判定，但结果只能作提示 —— 治理状态必须传导到 Fault。"""

    @pytest.mark.parametrize(
        ("source_type", "expected"),
        [
            pytest.param(SourceType.NATIONAL_STANDARD, True, id="national_standard"),
            pytest.param(SourceType.LITERATURE, True, id="literature"),
            pytest.param(SourceType.PENDING_REVIEW, False, id="pending_review"),
        ],
    )
    def test_scorable_follows_source_type(self, source_type: SourceType, expected: bool) -> None:
        engine = RuleEngine([make_rule()], make_table(make_threshold(source_type=source_type)))
        (fault,) = engine.evaluate_rep(make_window(make_frames([95.0, 96.0, 97.0])))
        # 注意：pending_review 不是「不判定」，而是「判定结果不计扣分」。
        assert fault.scorable is expected

    def test_missing_threshold_key_raises(self) -> None:
        engine = RuleEngine([make_rule(threshold_key="test.absent")], make_table())
        with pytest.raises(ThresholdError):
            engine.evaluate_rep(make_window(make_frames([95.0, 96.0, 97.0])))

    def test_no_usable_samples_means_threshold_lookup_is_skipped(self) -> None:
        # 当前实现先逐帧收集样本、无样本直接返回，之后才查阈值 —— 因此「阈值键
        # 不存在」这一配置错误在无数据的 rep 上不会暴露。此测试只锁定该顺序；
        # 若实现方认为配置错误应尽早暴露（如构造期校验），需同步修改本测试。
        engine = RuleEngine([make_rule(threshold_key="test.absent")], make_table())
        assert engine.evaluate_rep(make_window(make_frames([None, None]))) == ()


# ---------------------------------------------------------------------------
# Fault 形态：证据时间戳与值对象冻结
# ---------------------------------------------------------------------------


class TestFaultShape:
    """Fault / Deviation 是冻结值对象，证据只能是越界帧。"""

    def test_evidence_timestamps_contain_only_violating_frames_in_order(self) -> None:
        window = make_window(make_frames([98.0, 105.0, 97.0, 103.0, 96.0]))
        (fault,) = make_engine([make_rule()]).evaluate_rep(window)
        # 越界帧是下标 0/2/4；不越界的 105/103 帧绝不进入证据。
        assert fault.evidence_timestamps == (0, 2 * FRAME_MS, 4 * FRAME_MS)

    def test_fault_carries_rule_identity_and_governance(self) -> None:
        rule = make_rule(code="HEEL_RISE", name_zh="脚跟离地")
        (fault,) = make_engine([rule]).evaluate_rep(
            make_window(make_frames([98.0, 97.0, 96.0]))
        )
        assert fault.code == "HEEL_RISE"
        assert fault.name_zh == "脚跟离地"
        assert fault.scorable is True
        assert fault.deviation.feature == DEFAULT_METRIC

    def test_value_objects_are_frozen(self) -> None:
        window = make_window(make_frames([98.0, 97.0, 96.0]))
        fault = make_engine([make_rule()]).evaluate_rep(window)[0]
        with pytest.raises(FrozenInstanceError):
            fault.confidence = 0.0
        with pytest.raises(FrozenInstanceError):
            fault.deviation.measured = 0.0
        with pytest.raises(FrozenInstanceError):
            window.index = 99


# ---------------------------------------------------------------------------
# 组级聚合 evaluate_set
# ---------------------------------------------------------------------------


class TestSetAggregation:
    """组级统计。rate 描述的是「多少比例的 rep 出现该错误」，不是规则触发次数。

    因此同一 rep 内重复命中同一错误码只计一次：否则一个错误被两条规则同时
    命中（如 ASYMMETRY 由 knee_symmetry 与 pelvis_offset_ratio 各自判定）时，
    rate 会超过真实的问题 rep 占比。
    """

    def test_duplicate_hits_of_same_code_within_one_rep_count_once(self) -> None:
        # rep0 里 ASYMMETRY 被两条规则各命中一次：evaluate_rep 返回 2 条 Fault，
        # 但组级只能记 1 个 rep。若按触发次数累加，count=3、rate=1.0（虚高），
        # 而真实是 2 个 rep 出问题 / 3 个 rep，即 2/3。
        engine = _asymmetry_engine()
        windows = _asymmetry_windows()
        assert len(engine.evaluate_rep(windows[0])) == 2

        summary = engine.evaluate_set(windows)

        assert summary.rep_count == 3
        (stat,) = summary.fault_stats
        assert stat.code == "ASYMMETRY"
        assert stat.count == 2
        assert stat.rate == pytest.approx(0.6667)
        assert stat.rep_indices == (0, 1)

    def test_worst_delta_is_max_abs_over_all_hits_even_deduped(self) -> None:
        # rep0 的第二条同码命中（pelvis 0.21 → delta 0.11）不计数，但必须参与
        # 「最坏偏离」：取绝对值后的最大值，既不是均值也不是最后一次命中。
        summary = _asymmetry_engine().evaluate_set(_asymmetry_windows())
        (stat,) = summary.fault_stats
        assert stat.worst_delta == pytest.approx(0.11)

    def test_worst_delta_uses_absolute_value_of_signed_delta(self) -> None:
        # BELOW 规则的 delta_signed 为负，worst_delta 必须取其绝对值后的最大者
        # （10 > 3），并且取的是最大值而不是最后一个 rep 的 3。
        engine = make_engine([make_rule()])
        windows = (
            make_window(make_frames([90.0, 90.0, 90.0]), index=0),
            make_window(make_frames([97.0, 97.0, 97.0]), index=1),
        )
        (stat,) = engine.evaluate_set(windows).fault_stats
        assert stat.count == 2
        assert stat.rate == pytest.approx(1.0)
        assert stat.worst_delta == pytest.approx(10.0)

    def test_rep_indices_come_from_window_index_not_position(self) -> None:
        # rep_indices 报告 RepWindow.index（状态机给出的真实 rep 编号），不是
        # 枚举下标。聚合用 zip(windows, per_rep, strict=True) 对齐 —— 两者由同一
        # 序列派生、长度不可能不一致，strict 是防御性断言；本测试锁定的是
        # 「按输入顺序对齐」这一前提，以及 index 原样透出。
        engine = make_engine([make_rule()])
        windows = (
            make_window(make_frames([95.0, 95.0, 95.0]), index=7),
            make_window(make_frames([120.0, 120.0, 120.0]), index=9),
            make_window(make_frames([95.0, 95.0, 95.0]), index=11),
        )
        (stat,) = engine.evaluate_set(windows).fault_stats
        assert stat.rep_indices == (7, 11)
        assert stat.count == 2

    def test_scorable_faults_and_notices_split_by_governance(self) -> None:
        rules = [
            make_rule(code="SCORED_FAULT", name_zh="已核定错误", threshold_key="test.scored"),
            make_rule(code="NOTICE_FAULT", name_zh="待核定提示", threshold_key="test.pending"),
        ]
        thresholds = make_table(
            make_threshold("test.scored", value=100.0),
            make_threshold("test.pending", value=100.0, source_type=SourceType.PENDING_REVIEW),
        )
        windows = tuple(make_window(make_frames([95.0, 95.0, 95.0]), index=i) for i in range(2))
        summary = RuleEngine(rules, thresholds).evaluate_set(windows)

        assert tuple(stat.code for stat in summary.scorable_faults) == ("SCORED_FAULT",)
        assert tuple(stat.code for stat in summary.notices) == ("NOTICE_FAULT",)

    def test_fault_stats_are_sorted_by_code_regardless_of_rule_order(self) -> None:
        rules = [
            make_rule(code="Z_FAULT", name_zh="声明在前"),
            make_rule(code="A_FAULT", name_zh="排序在前"),
        ]
        window = make_window(make_frames([95.0, 95.0, 95.0]))
        summary = make_engine(rules).evaluate_set((window,))
        assert tuple(stat.code for stat in summary.fault_stats) == ("A_FAULT", "Z_FAULT")

    def test_primary_fault_picks_highest_rate(self) -> None:
        # COMMON 两条 rep 均命中（1.0），RARE 仅首条（0.5）。
        rules = [
            make_rule(
                code="COMMON",
                name_zh="常见错误",
                threshold_key="test.common",
                bad_side=Direction.BELOW,
            ),
            make_rule(
                code="RARE",
                name_zh="偶发错误",
                threshold_key="test.rare",
                bad_side=Direction.BELOW,
            ),
        ]
        thresholds = make_table(
            make_threshold("test.common", value=108.0),
            make_threshold("test.rare", value=100.0),
        )
        windows = (
            make_window(make_frames([95.0, 96.0, 97.0]), index=0),
            make_window(make_frames([105.0, 106.0, 107.0]), index=1),
        )
        primary = RuleEngine(rules, thresholds).evaluate_set(windows).primary_fault()
        assert primary is not None
        assert primary.code == "COMMON"
        assert primary.rate == pytest.approx(1.0)

    def test_primary_fault_breaks_rate_tie_by_worst_delta(self) -> None:
        # 两个错误码 rate 相同（都命中该 rep 内全部 3 帧，均为 1.0），
        # 此时按 worst_delta 取更大者（BIG 偏离 40，SMALL 只有 10）。
        rules = [
            make_rule(code="BIG_DELTA", name_zh="偏离大", threshold_key="test.big"),
            make_rule(code="SMALL_DELTA", name_zh="偏离小", threshold_key="test.small"),
        ]
        thresholds = make_table(
            make_threshold("test.big", value=90.0),
            make_threshold("test.small", value=60.0),
        )
        window = make_window(make_frames([50.0, 55.0, 58.0]), index=0)
        primary = RuleEngine(rules, thresholds).evaluate_set((window,)).primary_fault()
        assert primary is not None
        assert primary.code == "BIG_DELTA"  # 偏离 40 对 10

    def test_primary_fault_is_none_without_faults(self) -> None:
        summary = make_engine([make_rule()]).evaluate_set(
            (make_window(make_frames([120.0, 121.0, 122.0])),)
        )
        assert summary.fault_stats == ()
        assert summary.primary_fault() is None

    def test_empty_window_list_returns_empty_summary_without_raising(self) -> None:
        # rate 的分母是 rep 总数；0 个 rep 时实现用 `if total else 0.0` 兜底。
        # 实际约束更强：没有窗口就没有任何错误码、stats 为空，除法根本不会执行。
        summary = make_engine([make_rule()]).evaluate_set(())
        assert summary.rep_count == 0
        assert summary.fault_stats == ()
        assert summary.scorable_faults == ()
        assert summary.notices == ()
        assert summary.primary_fault() is None


# ---------------------------------------------------------------------------
# 已知实现偏差（xfail：断言「应有行为」，待实现方修复后会变为 XPASS）
# ---------------------------------------------------------------------------


class TestRuleValidation:
    """``Rule`` 的构造期校验。

    这组测试对应用户曾用 xfail 标记的两个实现缺陷。它们已在 ``Rule.__post_init__``
    中修复 —— 参数错误应在**定义动作时**立刻暴露，而不是等运行到某个特定数据组合
    才炸；那时错误现场（某次 rep 的某几帧）离病因（写错的规则参数）已经很远了。
    """

    def test_zero_min_violating_frames_is_rejected(self) -> None:
        # 取 0 会让「零越界帧」也越过帧数门槛，随后对空序列取极值时抛 ValueError。
        with pytest.raises(ValueError, match="min_violating_frames"):
            make_rule(min_violating_frames=0)

    def test_negative_min_violating_frames_is_rejected(self) -> None:
        with pytest.raises(ValueError, match="min_violating_frames"):
            make_rule(min_violating_frames=-1)

    def test_negative_severity_span_is_rejected(self) -> None:
        # 负 span 曾让 severity_0_1 输出负数，违反其声明的 0–1 契约。
        with pytest.raises(ValueError, match="severity_span"):
            make_rule(severity_span=-10.0)

    def test_boundary_values_are_accepted(self) -> None:
        # 合法边界：帧数下限取 1、span 取任意正数。
        assert make_rule(min_violating_frames=1).min_violating_frames == 1
        assert make_rule(severity_span=1e-9).severity_span == pytest.approx(1e-9)

    def test_none_severity_span_means_no_normalization(self) -> None:
        assert make_rule(severity_span=None).severity_span is None
