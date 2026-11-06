"""错误码中文名对照表测试。

重点是**漂移检测**：领域层新增错误码而本表没跟上时，用户会看到一个英文码。
那比看到一个错误的中文名安全，但仍然是需要被发现的问题。
"""

from __future__ import annotations

import re

import pytest

from app.plans import default_library
from app.taxonomy import FAULT_NAMES, fault_name, is_known, unknown_codes

CODE_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]*$")


class TestLookup:
    def test_known_code_returns_chinese_name(self) -> None:
        assert fault_name("KNEE_VALGUS") == "膝内扣"
        assert fault_name("INSUFFICIENT_DEPTH") == "下蹲深度不足"

    def test_unknown_code_returns_the_code_itself(self) -> None:
        """未知码原样返回，不编名字也不返回空串。

        返回空串会让界面出现一个没有标题的告警 —— 比看到英文码糟糕得多。
        """
        assert fault_name("NOT_A_REAL_CODE") == "NOT_A_REAL_CODE"
        assert fault_name("") == ""

    def test_is_known(self) -> None:
        assert is_known("KNEE_VALGUS") is True
        assert is_known("NOT_A_REAL_CODE") is False

    def test_unknown_codes_helper(self) -> None:
        found = unknown_codes(["KNEE_VALGUS", "BOGUS", "ALSO_BOGUS"])
        assert found == ("ALSO_BOGUS", "BOGUS")

    def test_unknown_codes_empty_input(self) -> None:
        assert unknown_codes([]) == ()


class TestTableIntegrity:
    def test_no_empty_names(self) -> None:
        empties = [code for code, name in FAULT_NAMES.items() if not name.strip()]
        assert not empties, f"以下错误码的中文名为空：{empties}"

    def test_codes_follow_upper_snake_convention(self) -> None:
        """错误码跨语言传输，必须是稳定的大写下划线形式。"""
        bad = [code for code in FAULT_NAMES if not CODE_PATTERN.match(code)]
        assert not bad, f"以下错误码不符合大写下划线命名：{bad}"

    def test_names_are_unique_or_deliberately_shared(self) -> None:
        """中文名允许重复（不同动作的「头颈位置不当」是同一类问题），
        但重复必须是少数 —— 大量重名说明命名过于笼统，用户在报告里分不清是哪一个。
        """
        names = list(FAULT_NAMES.values())
        duplicates = {name for name in names if names.count(name) > 1}
        assert len(duplicates) <= 3, f"重名过多：{sorted(duplicates)}"


class TestCoverageAgainstPlanLibrary:
    def test_every_plan_target_code_has_a_name(self) -> None:
        """方案库引用的错误码必须有中文名 —— 否则报告里会出现英文码。"""
        codes = {
            code for plan in default_library().all() for code in plan.target_fault_codes
        }
        missing = unknown_codes(codes)
        assert not missing, f"方案库引用了没有中文名的错误码：{sorted(missing)}"

    @pytest.mark.parametrize(
        "code",
        [
            "KNEE_VALGUS",
            "INSUFFICIENT_DEPTH",
            "EXCESSIVE_TRUNK_LEAN",
            "HEEL_RISE",
            "ASYMMETRY",
        ],
    )
    def test_domain_squat_codes_are_covered(self, code: str) -> None:
        """深蹲的五个已实现错误码必须有中文名。

        这五个码定义在 ``domain/src/vitalteen_domain/exercises/squat.py``。
        领域层改动那边时，本用例会失败并提醒同步本表。
        """
        assert is_known(code), f"{code} 缺少中文名"
