"""导出矫正方案库。

用法::

    python -m tools.export_plans            # 重新生成
    python -m tools.export_plans --check    # 只校验是否同步（CI 与本地自检）

**为什么需要它**

决策响应里的 ``choice.selected_plan_ids`` **只有 ID**（见 ``app/contracts.py`` 的
``PlanChoice``）：正文不进响应，为的是让一次结论可以被复现、让文案可以独立评审。
于是手机端要把它渲染成「练什么」那一段，就得自己手里有一份方案库。

**为什么全部导出，包括 ``draft``**

``for_faults_with_review_fallback`` 在没有已核定方案时会**退回未核定方案**，
并把「含未核定」一路传导到 ``dose_note``（见 ``app/plans.py`` 的模块文档）。
种子库现在全部是 draft —— 只导出 active 的话，端侧根本查不到响应里给的那些 ID，
用户看到的会是「这条建议不在本方案库中」，而那本该是极罕见的情形。

**为什么导出的是渲染结果而不是剂量数字**

``sets`` / ``reps`` / ``freq_per_week`` 都可能是 ``None``，而 ``None`` 的含义是
「尚未核定」而不是「不需要」。谁把这三个数字拼成句子，谁就要负责处理那三种空值 ——
让端侧再实现一遍 ``Dosage.describe()`` 就是再造一处会漂移的地方。
所以导出 ``dosage_text``（Python 侧的渲染结果）与 ``dosage_ratified`` 两个字段，
端侧只负责显示。

**为什么导出筛选与排序用的那几个字段**

``target_fault_codes`` / ``difficulty`` / ``age_min`` / ``age_max`` 曾经是刻意不导出的
——那时端侧拿到的是筛完的结果，只负责显示。现在不是了：手机端在**连不上决策服务**时
要自己从方案库里选（``app/lib/app/local_decision.dart``），而 ``for_faults`` 的过滤与
三级排序键（覆盖数 → 难度 → plan_id，见 ``app/plans.py``）全压在这四个字段上。
不导出它们，端侧选出来的方案与服务端就不是同一批。

**仍然刻意不导出的字段**：``category`` / ``grade_fit`` / ``evidence_refs`` /
``reviewed_by`` / ``reviewed_at``。前两个不参与筛选与排序，再显示一遍
「难度 2/5」这种没有图例的数字只会让报告变吵；``evidence_refs`` 是给评审看的，
端侧不展示；后两个是治理信息，属于方案库自己的账。

与 ``export_schema.py`` 一样提供 ``--check``：不同步就失败，逼迫改动者显式确认。
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from app.plans import CorrectionPlan, default_library

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_PATH = REPO_ROOT / "shared" / "plans" / "plan_library.json"

_COMMENT = [
    "VitalTeen 矫正方案库的快照，供手机端把决策响应里的 plan_id 渲染成正文。",
    "",
    "由 server/tools/export_plans.py 从 app/plans.py 导出。请勿手工编辑本文件 ——",
    "改方案请改 Python 定义后重新导出：cd server && python -m tools.export_plans",
    "",
    "⚠️ 全部方案都是 draft：动作与机制来自运动科学文献（有据可查），但组次剂量",
    "尚未经体育专业成员核定。这不是遗漏，是诚实的状态 —— 一个来源不明的",
    "「3 组 × 12 次」如果害得学生练出问题，责任是无法推脱的。",
    "",
    "剂量未核定时 dosage_text 就是「剂量待体育专业成员核定」，端侧必须原样显示，",
    "不能因为它是句套话就省略 —— 省略会让用户以为这个动作没有剂量要求。",
]


def _plan_payload(plan: CorrectionPlan) -> dict[str, Any]:
    return {
        "plan_id": plan.plan_id,
        "name_zh": plan.name_zh,
        "goal": plan.goal,
        "instructions": list(plan.instructions),
        "key_cues": list(plan.key_cues),
        "equipment": list(plan.equipment),
        "contraindications": list(plan.contraindications),
        "status": plan.status.value,
        "dosage_text": plan.dosage.describe(),
        "dosage_ratified": plan.dosage.is_ratified,
        # 下面四个是**筛选与排序**用的，端侧断网时靠它们复现 for_faults 的选择结果
        # （见模块文档「为什么导出筛选与排序用的那几个字段」）。
        "target_fault_codes": list(plan.target_fault_codes),
        "difficulty": plan.difficulty,
        "age_min": plan.age_min,
        "age_max": plan.age_max,
    }


def build() -> dict[str, Any]:
    library = default_library()
    return {
        "_comment": _COMMENT,
        "plans": [_plan_payload(plan) for plan in library.all()],
    }


def render(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="导出矫正方案库")
    parser.add_argument(
        "--check", action="store_true", help="仅校验现有文件是否与方案库同步，不写入"
    )
    args = parser.parse_args()

    payload = build()
    text = render(payload)

    if args.check:
        if not OUT_PATH.exists():
            print(f"方案库导出物不存在：{OUT_PATH}", file=sys.stderr)
            return 1
        if OUT_PATH.read_text(encoding="utf-8") != text:
            print(
                f"{OUT_PATH.relative_to(REPO_ROOT)} 与方案库不同步。\n"
                "若这是有意的方案改动，请运行 `python -m tools.export_plans` 重新导出 ——\n"
                "端侧渲染的正文就在那份文件里，不同步会让用户看到旧的动作要领。",
                file=sys.stderr,
            )
            return 1
        print(f"方案库导出物与实现同步：{OUT_PATH}")
        return 0

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(text, encoding="utf-8")
    counts = Counter(plan["status"] for plan in payload["plans"])
    breakdown = "，".join(f"{status} {count} 条" for status, count in sorted(counts.items()))
    print(f"已写入 {OUT_PATH}\n  共 {len(payload['plans'])} 条方案：{breakdown}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
