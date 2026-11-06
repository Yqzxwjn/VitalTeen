"""生成决策响应的跨语言一致性测试向量。

用法::

    python -m tools.build_response_fixture            # 重新生成
    python -m tools.build_response_fixture --check    # 只校验现有 fixture 是否同步

**为什么需要这个**

``app/lib/app/decision_response.dart`` 是**手写**的响应模型（理由与请求模型同：
生成只防「照 schema 抄错」，防不了两侧漂移，见 ``app/README.md``）。手写就要有东西
锁住它 —— 否则服务端把一个必填字段改名，端侧会一路解析到运行时才炸，而那时
用户已经做完一组动作了。

所以这里以**服务端为唯一生产者**产出真实的 ``DecisionResponse``，Dart 侧必须能解析它、
并把字段落进报告。这份锁是**单向**的：端侧不产出任何东西回来比对。

**为什么请求也一并放进来**

端侧报告要显示「第 2 次、第 5 次」这类逐次证据，而响应里只有 ``evidence.reps``
（次数下标）与一条恒为 ``null`` 的 ``evidence.metric`` —— 具体偏离多少度，得回
请求里按错误码 join。把 ``request`` 一起放进 fixture，Dart 侧那条 join 才有东西可测。

**为什么只有规则路径**

``laya=None`` 是服务端的合法配置，也是答辩现场断网时的实际路径。模型路径要求一个
能返回固定答案的假模型，而假模型不该出现在跨语言 fixture 里 —— 它一旦被当成
「服务端的真实输出」，fixture 就不再是证据。模型路径由 ``server/tests/test_service.py``
的鸭子类型桩覆盖。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from app.contracts import (
    CandidateIn,
    DecisionRequest,
    DecisionResponse,
    DeviationIn,
    FaultIn,
    FaultStatIn,
    RepIn,
)
from app.service import DecisionService

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = REPO_ROOT / "shared" / "fixtures" / "decision_response_conformance.json"

FIXTURE_VERSION = "1.0"

#: 场景说明。**每个场景的 note 都会一路进到 fixture 里给人看**，
#: 所以要写清「这个场景锁的是哪一条分支」以及「请求是合成的还是真流水线产的」。
#:
#: 前三个是**真实流水线**产出的请求；其余在**契约层** `model_copy` 合成 ——
#: 决策层只读请求，请求形状的真伪已经由 `decision_request_conformance.json`
#: 负责，这里不必再跑一遍流水线（也跑不出来：领域层不会产出「严重度恰好 0.125」
#: 这种值）。
SCENARIO_NOTES = {
    "ok": (
        "有候选错误的规则兜底路径。请求来自 build_request_fixture 的同一条真实流水线"
        "（标定 → 状态机 → 规则引擎 → 适配器），因此 deviations 是领域层真算出来的 —— "
        "端侧报告要 join 的就是这一份。"
    ),
    "clean": (
        "没有触发任何候选错误。这是**一条有效结论**，不是数据缺失：status 为 ok、"
        "faults 为空、满分。请求只把 candidates 清空，其余原样留着一一这条路径不读 rep 数据。"
    ),
    "abstain": (
        "数据质量不足，服务弃权。把关键点平均可见性压到 0.2（工程门限是 0.5）。"
        "端侧**不得**把它渲染成失败态：弃权是一条诚实的结论，不是错误。"
    ),
    "abstain_low_coverage": (
        "【合成】质量门第二条：有效帧占比压到 0.55（门限 0.6），可见性保持达标。"
        "与 abstain 分开是必要的 —— 两条门给出**不同的弃权理由**，而那段理由是端侧"
        "直接显示给用户的原文。"
    ),
    "abstain_no_reps": (
        "【合成】质量门第三条：一次完整动作都没记录到。请求**同时清空了 candidates**，"
        "钉住的是门的**顺序** —— 先判质量、再判有没有候选。顺序写反的实现会把这条"
        "渲染成「动作没问题，100 分」，那是把「没测到」说成了「测得好」。"
    ),
    "primary_by_count": (
        "【合成】主问题取**候选集内出现次数最多**的那个，而不是候选集第一项。"
        "这里候选序是 [深度不足, 膝内扣]，而命中次数是 1 : 2。同一条也钉住"
        "**faults 的顺序跟着候选集走**（不跟着 fault_stats），因为报告里"
        "「其余问题」那一段直接反映这个顺序。"
    ),
    "primary_tie_first_stat": (
        "【合成】并列时取 `fault_stats` 里的**首个**极大元素（Python `max` 的语义）。"
        "注意这里 fault_stats 的顺序与候选序**故意相反**：用 `>=` 推进的实现会取到"
        "最后一个极大元素，结果依然「是个并列项」，所以不会崩 —— 只会让断网与联网"
        "两端的报告偶尔对不上。"
    ),
    "severity_unknown_vs_zero": (
        "【合成】**未知与零不是一回事。** 深度不足带一条 severity_0_1 == 0.0 的偏离"
        "（真零），脚跟离地没有任何偏离明细（未知，退回出现率）。把未知填成零的实现"
        "会给出两份一模一样的报告，而其中一份本该是「10 次里犯了 5 次」。"
    ),
    "severity_rounding": (
        "【合成】0.125 与 0.375 在二进制里是**精确值**，×100 后恰好落在 12.5 与 37.5 上 ——"
        "真并列。Python 的 round 进位到偶数（12 / 38），Dart 原生的 round 远离零（13 / 38）。"
        "可见性同时取 0.90625，钉住 `round(x, 4)` 的同一个行为（0.9062，不是 0.9063）。"
    ),
    "stats_disjoint": (
        "【合成】`fault_stats` 与 `candidates` **完全不相交**（这是端侧只升级了一半时"
        "会出现的形状）。主问题退回候选集首项以保证契约成立（primary_fault 必须出现在"
        "faults 里），证据则如实为空 —— 不是编一个。"
    ),
    "no_reps_thin": (
        "【合成】`reps` 为空但组级统计在 —— 端侧只上报聚合结果时会是这样。"
        "严重度退回**出现率**（「2 次里犯 2 次」），而不是当作零。"
        "这是可以接受的近似：它用的是真实上报的数据，只是换了维度。"
    ),
    "plans_equipment": (
        "【合成】器材过滤 + 覆盖数优先排序。候选 [膝内扣, 左右不对称]，用户手上有弹力带。"
        "覆盖 2 个码的弹力带侧向行走排第一（尽管它难度 2），后面才轮到覆盖 1 个码的。"
        "没有这条，端侧的器材子集判断错了也没人知道。"
    ),
    "plans_age_filter": (
        "【合成】年龄过滤。年龄压到 11 —— 内置方案库全部是 12–18 岁，因此一条方案都"
        "选不出来。这条同时锁住「有错误但没有建议」这个组合的渲染：`choice` 为 null "
        "而 faults 非空，报告不能因此留白或崩掉。"
    ),
}


def _zero_latency(response: DecisionResponse) -> DecisionResponse:
    """把 ``latency_ms`` 归零。

    它是唯一每次都不同的字段，留着会让 ``--check`` 永远红。归零而不是删掉：
    端侧模型必须仍然能解析它 —— 「响应里有一个我们不用的必填字段」正是这条
    跨语言锁要覆盖的形状。
    """
    return response.model_copy(
        update={"meta": response.meta.model_copy(update={"latency_ms": 0})}
    )


def _scenario(
    name: str,
    request: DecisionRequest,
    response: DecisionResponse,
    equipment: tuple[str, ...] = (),
) -> dict[str, Any]:
    return {
        "name": name,
        "note": SCENARIO_NOTES[name],
        "request": request.model_dump(mode="json"),
        # 用户手上有哪些器材会影响选方案。绝大多数场景用默认值（徒手），
        # 单独记下来是因为「端侧拿什么去选」也是这条锁的一部分。
        **({"available_equipment": list(equipment)} if equipment else {}),
        "expected_response": _zero_latency(response).model_dump(mode="json"),
    }


# ---------------------------------------------------------------------------
# 合成请求
#
# 下面这些 helper 只在**契约层**改字段，不碰领域层 —— 决策层读的就是这些字段，
# 而请求形状本身的真伪由 decision_request_conformance.json 负责。
# ---------------------------------------------------------------------------

#: 一条偏离的几何数字取自 `ok` 场景那条真流水线产出的偏离，只换 severity_0_1。
#: 换掉几何数字没有意义：决策层只看 severity_0_1，而 measured/threshold 保持
#: 真实值可以让「报告里那一行数字长什么样」也一并被锁住。
_DEVIATION_FEATURE = "knee_angle_L"
_DEVIATION_MEASURED = 119.5923
_DEVIATION_THRESHOLD = 100.0


def _fault(code: str, severity: float | None) -> FaultIn:
    return FaultIn(
        code=code,
        confidence=1.0,
        evidence_frames=[3706, 3739, 3772],
        deviations=[
            DeviationIn(
                feature=_DEVIATION_FEATURE,
                measured=_DEVIATION_MEASURED,
                threshold=_DEVIATION_THRESHOLD,
                delta_signed=_DEVIATION_MEASURED - _DEVIATION_THRESHOLD,
                severity_0_1=severity,
            )
        ],
    )


def _reps(*entries: tuple[int, tuple[tuple[str, float | None], ...]]) -> list[RepIn]:
    """按 ``(下标, ((错误码, 严重度), ...))`` 造逐次明细。"""
    return [
        RepIn(
            index=index,
            duration_ms=800,
            phases_ms={"descent": 200, "bottom": 400, "ascent": 200},
            metrics={},
            faults=[_fault(code, severity) for code, severity in faults],
            confidence=None,
        )
        for index, faults in entries
    ]


def _stats(*entries: tuple[str, tuple[int, ...]]) -> list[FaultStatIn]:
    """按 ``(错误码, 出现的那几次)`` 造组级统计。``count`` 由 reps 长度推出 ——
    契约要求两者一致，写两遍迟早会写岔。"""
    return [
        FaultStatIn(code=code, reps=list(indices), count=len(indices))
        for code, indices in entries
    ]


def _with_stats(request: DecisionRequest, stats: list[FaultStatIn]) -> DecisionRequest:
    """只换 `set.fault_stats`，其余（含 rep_count）原样留着。

    `rep_count` 不动是刻意的：出现率的分母是它，改它会同时改掉严重度 ——
    而每个场景只想动一个变量。
    """
    return request.model_copy(
        update={"set": request.set.model_copy(update={"fault_stats": stats})}
    )


def build() -> dict[str, Any]:
    from tools.build_request_fixture import build as build_request_payload

    request = DecisionRequest.model_validate(build_request_payload()["expected_request"])
    service = DecisionService(laya=None)
    equipment = ("弹力带",)

    # ---- 三种结局：ok / clean / abstain，全部来自真流水线 -------------------
    clean_request = request.model_copy(update={"candidates": []})

    def _quality(**updates: Any) -> DecisionRequest:
        return request.model_copy(
            update={"pose_quality": request.pose_quality.model_copy(update=updates)}
        )

    def _candidates(*codes: str) -> DecisionRequest:
        return request.model_copy(
            update={
                "candidates": [
                    CandidateIn(code=code, triggered_by_rule="rule_engine") for code in codes
                ]
            }
        )

    def _age(age: int) -> DecisionRequest:
        return request.model_copy(
            update={"context": request.context.model_copy(update={"age": age})}
        )

    # ---- 场景表 -----------------------------------------------------------
    #
    # 顺序不重要（Dart 侧按名字取），但**从简到繁**排方便人读：
    # 弃权两条 → 主问题三条 → 严重度三条 → 方案两条。
    cases: list[tuple[str, DecisionRequest, tuple[str, ...]]] = [
        ("ok", request, ()),
        ("clean", clean_request, ()),
        ("abstain", _quality(mean_visibility=0.2), ()),
        # 质量门第二、三条。
        ("abstain_low_coverage", _quality(coverage_ok_ratio=0.55), ()),
        (
            "abstain_no_reps",
            _candidates().model_copy(
                update={
                    "reps": [],
                    "set": request.set.model_copy(
                        update={"rep_count": 0, "valid_rep_count": 0, "fault_stats": []}
                    ),
                }
            ),
            (),
        ),
        # 主问题怎么挑。
        (
            "primary_by_count",
            _with_stats(
                _candidates("INSUFFICIENT_DEPTH", "KNEE_VALGUS"),
                _stats(("INSUFFICIENT_DEPTH", (2,)), ("KNEE_VALGUS", (1, 2))),
            ),
            (),
        ),
        (
            "primary_tie_first_stat",
            _with_stats(
                _candidates("INSUFFICIENT_DEPTH", "KNEE_VALGUS"),
                _stats(("KNEE_VALGUS", (1, 2)), ("INSUFFICIENT_DEPTH", (1, 2))),
            ),
            (),
        ),
        # 严重度：未知、零、以及与 Python 舍入对齐。
        (
            "severity_unknown_vs_zero",
            _with_stats(
                _candidates("INSUFFICIENT_DEPTH", "HEEL_RISE"),
                _stats(("INSUFFICIENT_DEPTH", (2,)), ("HEEL_RISE", (1,))),
            ).model_copy(update={"reps": _reps((2, (("INSUFFICIENT_DEPTH", 0.0),)))}),
            (),
        ),
        (
            "severity_rounding",
            _with_stats(
                _candidates("INSUFFICIENT_DEPTH", "KNEE_VALGUS"),
                _stats(("INSUFFICIENT_DEPTH", (1,)), ("KNEE_VALGUS", (2,))),
            ).model_copy(
                update={
                    "reps": _reps(
                        (1, (("INSUFFICIENT_DEPTH", 0.125),)),
                        (2, (("KNEE_VALGUS", 0.375),)),
                    ),
                    "pose_quality": request.pose_quality.model_copy(
                        update={"mean_visibility": 0.90625}
                    ),
                }
            ),
            (),
        ),
        (
            "stats_disjoint",
            _with_stats(
                _candidates("INSUFFICIENT_DEPTH", "KNEE_VALGUS"),
                _stats(("HEEL_RISE", (1,))),
            ),
            (),
        ),
        (
            "no_reps_thin",
            _with_stats(
                _candidates("INSUFFICIENT_DEPTH"),
                _stats(("INSUFFICIENT_DEPTH", (1, 2))),
            ).model_copy(update={"reps": []}),
            (),
        ),
        # 方案的筛选与排序。
        (
            "plans_equipment",
            _with_stats(
                _candidates("KNEE_VALGUS", "ASYMMETRY"),
                _stats(("KNEE_VALGUS", (1, 2)), ("ASYMMETRY", (2,))),
            ),
            equipment,
        ),
        ("plans_age_filter", _age(11), ()),
    ]

    missing = {name for name, _, _ in cases} ^ set(SCENARIO_NOTES)
    if missing:
        # 加了场景却忘了写 note（或反过来）时当场炸。漏了 note 的 fixture
        # 依然能用，只是没人知道那个场景在锁什么 —— 那种锁早晚会被当成噪声删掉。
        raise ValueError(f"场景与 note 对不上：{sorted(missing)}")

    return {
        "fixture_version": FIXTURE_VERSION,
        "note": (
            "由 server/tools/build_response_fixture.py 生成。"
            "Dart 侧必须能解析 expected_response 并把字段落进报告 —— "
            "见 app/test/app/decision_response_conformance_test.dart；"
            "并必须能用同一份 request 在本机算出逐字段相同的响应 —— "
            "见 app/test/app/local_decision_conformance_test.dart。"
        ),
        "decided_with": "rule-only",
        "scenarios": [
            _scenario(name, req, service.decide(req, available_equipment=equip), equip)
            for name, req, equip in cases
        ],
    }


def render(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="生成决策响应的跨语言一致性测试向量")
    parser.add_argument(
        "--check", action="store_true", help="仅校验现有 fixture 是否与当前实现同步，不写入"
    )
    args = parser.parse_args()

    text = render(build())

    if args.check:
        if not FIXTURE_PATH.exists():
            print(f"fixture 不存在：{FIXTURE_PATH}", file=sys.stderr)
            return 1
        if FIXTURE_PATH.read_text(encoding="utf-8") != text:
            print(
                "响应 fixture 与当前实现不同步。\n"
                "若这是有意的行为变更，请运行 `python -m tools.build_response_fixture` "
                "重新生成，并同时确认端侧的手写模型跟得上 —— 这份文件就是端侧模型的锁；\n"
                "若是意外漂移，说明决策服务的输出变了而没人注意到。",
                file=sys.stderr,
            )
            return 1
        print(f"响应 fixture 与实现同步：{FIXTURE_PATH}")
        return 0

    FIXTURE_PATH.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE_PATH.write_text(text, encoding="utf-8")
    payload = json.loads(text)
    summary = "，".join(
        f"{item['name']}:{item['expected_response']['status']}" for item in payload["scenarios"]
    )
    print(f"已写入 {FIXTURE_PATH}\n  {len(payload['scenarios'])} 个场景（{summary}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
