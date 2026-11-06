"""模板表与决策服务的一致性。

服务端只回 ``template_id``，正文在 ``shared/messages/teen_v1.json`` 里 —— 于是这条
链路的两半分居两个包、两种语言。**任何一半对不上都不会报错**：服务端拼出一个端侧
没有的 ID，用户看到的是兜底文案；端侧多写一条永远不被渲染的模板，没人会发现。
两者都是静默失效，所以在这里拦。

本文件检查三件事：

1. **已实现动作的**每一个错误码，跑一遍**真实的**决策服务，产出的 ``template_id``
   都在这份表里；
2. 表里每个模板用到的占位符，都在服务端会写进 ``params`` 的键里；
3. 表里没有「动作产不出来的模板」—— 照着 ``taxonomy.py`` 的几十个码写满是
   最容易犯的错，那些码对应的动作还没实现，写出来只是每次评审都要多过一遍的死文案。

检查按动作遍历（见 :data:`ACTION_DEFINITIONS`），因为模板 ID 里的动作码与错误码
都来自动作定义：加了新动作却不加模板，第 1 条会红；加了模板却没有动作定义，
第 3 条会红。两者都是**没有测试就不会有人发现**的那类缺陷。

模板的**措辞**不在这里测 —— 那是传播学评审的事，不是回归测试能判的。
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import pytest

pytest.importorskip("vitalteen_domain", reason="需要 domain/ 包才能枚举动作的错误码")

from vitalteen_domain.exercises import (
    Calibration,
    build_jj,
    build_plank,
    build_pu,
    build_pullup,
    build_rope,
    build_slj,
    build_squat,
    build_su,
)

from app.service import DecisionService

CATALOG_PATH = Path(__file__).resolve().parents[2] / "shared" / "messages" / "teen_v1.json"

#: ``_build_message`` 会写进 ``params`` 的全部键。改动那里时这份集合要同步 ——
#: 下面 ``test_params_stay_within_the_documented_keys`` 会在服务端多写出一个
#: 键时失败，提醒把它记到这里来。
DOCUMENTED_PARAMS = {"total", "valid", "primary", "primary_count", "note"}

_PLACEHOLDER = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")

#: 已经实现、因而**应当**有文案的动作定义。
#:
#: 用动作定义而不是手抄的错误码清单：手抄的清单会随领域层新增规则而悄悄少一项，
#: 而少掉的那一项正好就是没有模板的那一个 —— 失败方式与这个测试要防的完全一样。
ACTION_DEFINITIONS = {
    "SQUAT": build_squat(
        Calibration(knee_angle=175.0, trunk_lean=2.0, heel_rise_ratio=0.0, frames=20)
    ),
    "SLJ": build_slj(
        Calibration(knee_angle=175.0, trunk_lean=2.0, heel_rise_ratio=0.0, frames=20)
    ),
    # 开合跳的基线集不含脚跟抬升（正面机位下采不到），**但含分腿比** ——
    # `build_jj` 在它缺席时直接抛，所以这里不能照抄上面两行的 Calibration。
    "JJ": build_jj(
        Calibration(
            knee_angle=175.0,
            trunk_lean=2.0,
            heel_rise_ratio=None,
            frames=20,
            leg_spread=0.3,
        )
    ),
    # 俯卧撑走 45° 主链路，基线四项里只有脚跟抬升用不上 —— 但 `build_pu`
    # 一条基线都不读，所以这里给一个**完整**的 Calibration 就够了。
    "PU": build_pu(
        Calibration(knee_angle=175.0, trunk_lean=2.0, heel_rise_ratio=0.0, frames=20)
    ),
    # 仰卧起坐同样走 45° 主链路，同样一条基线都不读 —— 但 `Calibration` 的字段
    # 在这儿一个都不能省（`build_su` 不读它，读它的是 `Calibrator` 的门槛）。
    "SU": build_su(
        Calibration(knee_angle=175.0, trunk_lean=2.0, heel_rise_ratio=0.0, frames=20)
    ),
    # 跳绳走 45° 主链路，但它的基线集里有一个别处没有的量：`foot_height`
    # （站立时脚尖高出画面下缘多少）—— 它是那三条分段线的零点，缺席时
    # `build_rope` 直接抛（不是取 0），所以这里必须给上。**不传口径的后果
    # 见 rope.py 文件头：绝对高度由机位高度决定，取 0 会让整组判据变成
    # 「手机架得对不对」。**
    "ROPE": build_rope(
        Calibration(
            knee_angle=175.0,
            trunk_lean=2.0,
            heel_rise_ratio=0.0,
            frames=20,
            foot_height=1.0,
        )
    ),
    # 引体向上走 45° 主链路，三条判定全是绝对量、一条基线都不读 ——
    # 与俯卧撑、仰卧起坐一样，这里给一个完整的 Calibration 就够了
    # （真正在乎基线的是 `Calibrator` 的门槛，不是 `build_pullup`）。
    "PULLUP": build_pullup(
        Calibration(knee_angle=175.0, trunk_lean=2.0, heel_rise_ratio=0.0, frames=20)
    ),
    # 平板支撑同样走 45° 主链路，三条判定（四条规则）全是绝对量、一条基线都不读
    # —— 与俯卧撑、仰卧起坐、引体向上一样，给一个完整的 Calibration 就够了。
    #
    # **它是第一个计时制的动作**：这里的 `rep_count` 数的是「撑住的那一段」的段数，
    # 而模板措辞按这个语义写（「这一组撑了 N 段」），不是「N 次」——
    # 模板的措辞不归这个测试管，但**段数这个词与领域层的 rep 语义对得上**：
    # 一次 rep 就是一段连续的支撑。
    "PLANK": build_plank(
        Calibration(knee_angle=175.0, trunk_lean=2.0, heel_rise_ratio=0.0, frames=20)
    ),
}


@pytest.fixture(scope="module")
def catalog() -> dict[str, Any]:
    if not CATALOG_PATH.exists():
        pytest.skip(f"模板表不存在（单独 checkout server/ 时正常）：{CATALOG_PATH}")
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def codes_for(action_code: str) -> tuple[str, ...]:
    """该动作定义里声明的错误码。"""
    return tuple(rule.code for rule in ACTION_DEFINITIONS[action_code].rules)


def context_for(action_code: str, request_factory):
    """把基底请求的 ``context`` 整块换成目标动作。

    要换整块而不是只传 ``action_code``：``request_factory`` 对顶层键做 update，
    只传一个 ``action_code`` 会变成往请求里塞一个无关键，真正的上下文还是深蹲。
    """
    context = dict(request_factory().context.model_dump())
    context["action_code"] = action_code
    return context


def request_for(code: str, action_code: str, request_factory):
    """构造一份「只有这一个候选错误」的请求：主问题必为该码，模板 ID 由它决定。"""
    return request_factory(
        context=context_for(action_code, request_factory),
        set={
            "rep_count": 10,
            "valid_rep_count": 9,
            "fault_stats": [{"code": code, "reps": [1, 2, 3], "count": 3}],
        },
        reps=[],
        candidates=[{"code": code, "triggered_by_rule": f"{code} > T"}],
    )


def clean_request(action_code: str, request_factory):
    """该动作的「没有候选错误」请求：走 clean 模板那条分支。"""
    return request_factory(context=context_for(action_code, request_factory), candidates=[])


def _ids_produced_by_the_service(action_code: str, request_factory) -> set[str]:
    """跑一遍真实服务，收集该动作路径能产出的全部模板 ID。"""
    service = DecisionService(laya=None)
    ids = {service.decide(clean_request(action_code, request_factory)).message.template_id}  # type: ignore[union-attr]
    for code in codes_for(action_code):
        response = service.decide(request_for(code, action_code, request_factory))
        assert response.message is not None
        ids.add(response.message.template_id)
    return ids


class TestTemplateCoverage:
    @pytest.mark.parametrize("action_code", sorted(ACTION_DEFINITIONS))
    def test_every_code_has_a_template(self, action_code, catalog, request_factory) -> None:
        known = set(catalog["templates"])
        for code in codes_for(action_code):
            response = DecisionService(laya=None).decide(
                request_for(code, action_code, request_factory)
            )
            template_id = response.message.template_id  # type: ignore[union-attr]
            assert template_id in known, (
                f"{code} 产出的 template_id「{template_id}」不在模板表里，"
                "端侧只能落进兜底文案。补进 shared/messages/teen_v1.json。"
            )

    @pytest.mark.parametrize("action_code", sorted(ACTION_DEFINITIONS))
    def test_no_dead_templates(self, action_code, catalog, request_factory) -> None:
        """反向也要查：写了但永远不会被渲染的模板同样是缺陷。

        照着 taxonomy 的几十个码写满，看起来「覆盖完整」，实际大部分模板对应的
        动作都还没实现 —— 它们永远不会出现在屏幕上，却要跟着每次文案评审过一遍。
        """
        produced = _ids_produced_by_the_service(action_code, request_factory)
        prefix = f"msg_{action_code.lower()}_"
        declared = {tid for tid in catalog["templates"] if tid.startswith(prefix)}
        assert declared == produced, {
            "只有声明没有产出": sorted(declared - produced),
            "只有产出没有声明": sorted(produced - declared),
        }

    def test_fallback_exists(self, catalog) -> None:
        """兜底 ID 必须真的在表里 —— 否则兜底文案本身找不到，等于没有兜底。"""
        assert catalog["fallback_template_id"] in catalog["templates"]

    def test_fallback_uses_no_placeholder_it_cannot_guarantee(self, catalog) -> None:
        """兜底文案在「服务端什么都没给」时也要能渲染出来。"""
        text = catalog["templates"][catalog["fallback_template_id"]]["text"]
        assert set(_PLACEHOLDER.findall(text)) <= {"total", "valid"}


class TestPlaceholderContract:
    def test_placeholders_are_ones_the_service_produces(self, catalog) -> None:
        for template_id, entry in catalog["templates"].items():
            used = set(_PLACEHOLDER.findall(entry["text"]))
            unknown = used - DOCUMENTED_PARAMS
            assert not unknown, (
                f"{template_id} 用了服务端产不出的占位符：{sorted(unknown)}。"
                "端侧不会硬填它们，整句会作废改用兜底文案。"
            )

    def test_params_stay_within_the_documented_keys(self, request_factory) -> None:
        """反向：服务端别偷偷多写一个键而不更新这里的清单。

        多写的键本身无害（端侧只取模板里用到的），但它意味着模板可以开始用一个新的
        数据来源，而那件事应当是有意识的。
        """
        service = DecisionService(laya=None)
        seen: set[str] = set()
        for action_code in sorted(ACTION_DEFINITIONS):
            seen.update(  # type: ignore[union-attr]
                service.decide(clean_request(action_code, request_factory)).message.params
            )
            for code in codes_for(action_code):
                response = service.decide(request_for(code, action_code, request_factory))
                seen.update(response.message.params)  # type: ignore[union-attr]
        assert seen <= DOCUMENTED_PARAMS, (
            f"服务端写出了未登记的 params 键：{sorted(seen - DOCUMENTED_PARAMS)}"
        )

    def test_templates_do_not_use_the_note_placeholder(self, catalog) -> None:
        """``note`` 是「明细降级」的说明，由报告单列为一条口径声明。

        它混进总述句里会变成半截话，而且降级与否是**整份响应**的属性，
        不是某一句话的属性。
        """
        for template_id, entry in catalog["templates"].items():
            assert "{note}" not in entry["text"], f"{template_id} 不该把 note 占位符写进句子"
