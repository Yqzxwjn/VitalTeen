"""导出决策服务的工程参数。

用法::

    python -m tools.export_rule_settings            # 重新生成
    python -m tools.export_rule_settings --check    # 只校验是否同步（CI 与本地自检）

**为什么需要它**

手机端要能**在连不上决策服务时，在本机算出一份与服务端一致的报告**。判定逻辑可以
在 Dart 里重写一遍，但数字不行 —— 一个 0.5 写成 0.6，产出的是一份**看起来正常、
其实结论不同**的报告，没有任何东西会报错。所以这些参数必须有一份双方都读的真源。

真源是 :class:`app.service.DecisionSettings`（代码），这份 JSON 是它的快照。方向是单向的：
**改参数请改代码，再重新导出。**

**为什么不放进 ``shared/thresholds/``**

那份文件里的每一条都带 ``source_type`` / ``pending_review``，治理语义是
「体育阈值、仅体育专业成员可改、未核定的不得驱动扣分」。而这里是工程参数
（``service.py`` 的类文档写得很清楚：技术选择，工程师可以调，不参与扣分）。
混在一起会让两边各自的治理都失效 —— 尤其是 ``ThresholdTable`` 会按 ``thresholds[]``
逐条解析，多出这么一段无关键，要么被静默忽略、要么让端侧加载器炸。

**刻意不导出的字段**

``model_version``：端侧本机永远不声称自己走了决策模型。
``severity_labels``（"轻"/"中"/"重"）：那是喂给 Laya 的 ``score`` 原语的档位词，
规则兜底路径只输出数字档位，用不到。
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import fields
from pathlib import Path
from typing import Any

from app.service import DecisionSettings

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_PATH = REPO_ROOT / "shared" / "decision" / "rule_settings.json"

#: 导出哪些字段。**用白名单而不是 ``dataclasses.asdict``** —— 后者会把将来新增的
#: 每个字段自动带进来，包括那些端侧根本不该知道的（比如模型标识）。多导一个字段
#: 不报错，只会让端侧手里多一份会过期的数据。
_EXPORTED_FIELDS: tuple[str, ...] = (
    "min_mean_visibility",
    "min_coverage_ratio",
    "max_plans",
    "severity_level_breakpoints",
    "score_worst_weight",
    "score_mean_weight",
    "rating_cutoffs",
    "rating_labels",
    "fallback_model_version",
)

#: 刻意**不**导出的字段，连同理由。``unknown_fields`` 管不到这一侧 ——
#: 字段被删掉会被它抓住，但**新增**一个设置项时谁也不会提醒你「端侧要不要」。
#: ``test_export_rule_settings`` 用这份表要求两者恰好覆盖 ``DecisionSettings``：
#: 新增字段却两个表都没更新，测试红，那一刻必须显式做个决定。
EXCLUDED_FIELDS: dict[str, str] = {
    "model_version": "端侧本机永远不声称自己走了决策模型",
    "severity_labels": "喂给 Laya 的 score 原语的档位词，规则兜底路径只输出数字档位",
}

_COMMENT = [
    "决策服务的工程参数快照，供手机端在连不上服务时在本机复现同一套判定。",
    "",
    "由 server/tools/export_rule_settings.py 从 app/service.py 的 DecisionSettings 导出。",
    "请勿手工编辑本文件 —— 改参数请改代码后重新导出：",
    "cd server && python -m tools.export_rule_settings",
    "",
    "这些是**工程参数，不是体育阈值**，所以不在 shared/thresholds/ 里：它们是技术选择、",
    "不参与扣分，工程师可以调，改完只需重跑回归测试。",
    "",
    "⚠️ 端侧读的就是这份。改了服务端却忘了重新导出，表现是「同一组动作，手机断网时",
    "给出的结论与联网时不同」—— 而那种不一致不会报错，只会让人怀疑数据。",
]


def _value(settings: DecisionSettings, name: str) -> Any:
    value = getattr(settings, name)
    return list(value) if isinstance(value, tuple) else value


def build() -> dict[str, Any]:
    settings = DecisionSettings()
    return {
        "_comment": _COMMENT,
        **{name: _value(settings, name) for name in _EXPORTED_FIELDS},
    }


def render(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False) + "\n"


def unknown_fields() -> list[str]:
    """白名单里写了、但 ``DecisionSettings`` 已经没有的字段名。

    字段改名是个静默的失败：``getattr`` 会抛，但抛在导出**运行**时而不是**改代码**时；
    更糟的是如果哪天有人用 ``asdict`` 兜底，改名就会表现为「端侧少了一个参数」
    而导出照常成功。单独把它拎出来给测试用。
    """
    known = {field.name for field in fields(DecisionSettings)}
    return [name for name in _EXPORTED_FIELDS if name not in known]


def main() -> int:
    parser = argparse.ArgumentParser(description="导出决策服务的工程参数")
    parser.add_argument(
        "--check", action="store_true", help="仅校验现有文件是否同步，不写入"
    )
    args = parser.parse_args()

    missing = unknown_fields()
    if missing:
        print(
            f"白名单里的字段在 DecisionSettings 里不存在：{missing}\n"
            "多半是字段被改名或删掉了，请同步更新 _EXPORTED_FIELDS。",
            file=sys.stderr,
        )
        return 1

    payload = build()
    text = render(payload)

    if args.check:
        if not OUT_PATH.exists():
            print(f"工程参数导出物不存在：{OUT_PATH}", file=sys.stderr)
            return 1
        if OUT_PATH.read_text(encoding="utf-8") != text:
            print(
                f"{OUT_PATH.relative_to(REPO_ROOT)} 与 DecisionSettings 不同步。\n"
                "若这是有意的参数改动，请运行 `python -m tools.export_rule_settings` 重新导出 ——\n"
                "手机端断网时在本机复现判定读的就是那份文件，不同步会让两侧结论不一致。",
                file=sys.stderr,
            )
            return 1
        print(f"工程参数导出物与实现同步：{OUT_PATH}")
        return 0

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(text, encoding="utf-8")
    print(f"已写入 {OUT_PATH}\n  共 {len(_EXPORTED_FIELDS)} 个参数")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
