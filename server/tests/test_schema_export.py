"""契约 schema 同步测试。

守的是「契约改了却没重新导出」这个失误 —— 端侧拿着过期的 schema 做代码生成，
生成的模型与服务端对不上，而那种错会一路拖到联调才暴露。
"""

from __future__ import annotations

import json

import pytest

from app.contracts import MAX_CANDIDATES, SCHEMA_VERSION, DecisionRequest, DecisionResponse
from tools.export_schema import OUT_DIR, SCHEMAS, build


class TestExport:
    def test_build_produces_every_declared_schema(self) -> None:
        assert set(build()) == set(SCHEMAS)

    def test_output_is_valid_json(self) -> None:
        for name, text in build().items():
            parsed = json.loads(text)
            assert "properties" in parsed, f"{name} 缺少 properties"

    def test_comment_marks_the_file_as_generated(self) -> None:
        """手工编辑导出物是这类文件最常见的死法，注释要说清楚。"""
        for text in build().values():
            assert "请勿手工编辑" in json.loads(text)["$comment"]


class TestSyncWithContract:
    """导出物必须与 contracts.py 保持一致。"""

    @pytest.mark.parametrize("filename", sorted(SCHEMAS))
    def test_file_exists(self, filename: str) -> None:
        path = OUT_DIR / filename
        assert path.exists(), (
            f"{path} 不存在。请运行 `python -m tools.export_schema` 生成 —— "
            "端侧需要它来做代码生成与本地校验。"
        )

    @pytest.mark.parametrize("filename", sorted(SCHEMAS))
    def test_file_is_in_sync(self, filename: str) -> None:
        path = OUT_DIR / filename
        assert path.exists(), f"{path} 缺失，请先运行导出脚本"
        assert path.read_text(encoding="utf-8") == build()[filename], (
            f"{filename} 与契约不同步。若是有意的契约变更，请重新导出并在提交信息里说明；"
            "若是意外漂移，说明有人改了契约却没走导出流程。"
        )


class TestSchemaContent:
    def test_request_schema_declares_the_candidate_limit(self) -> None:
        """候选集上限必须体现在 schema 里，端侧才能在本地就拦住 ——
        而不是把 25 个候选发到服务端等一个 400。

        这条曾经失败过：上限由自定义校验器强制，而 Pydantic 的 schema 导出
        只反映声明式约束，于是导出的 schema 里根本没有 `maxItems`，
        端侧照着它生成的模型会漏掉这条限制。
        """
        schema = DecisionRequest.model_json_schema()
        candidates = schema["properties"]["candidates"]
        assert candidates.get("maxItems") == MAX_CANDIDATES, candidates

    def test_request_schema_requires_the_contract_version(self) -> None:
        """契约版本是端侧判断「我这套模型还算不算新」的唯一依据。"""
        schema = DecisionRequest.model_json_schema()
        assert "schema_version" in schema.get("required", []), schema.get("required")

    def test_response_schema_carries_abstain_reason(self) -> None:
        """弃权是这套系统的核心诚实机制，端侧必须能拿到它的原因。"""
        schema = DecisionResponse.model_json_schema()
        assert "abstain_reason" in schema["properties"]

    def test_schemas_are_serialisable_with_chinese(self) -> None:
        """字段描述里有中文，导出时必须保留而不是转义成 \\uXXXX。"""
        for text in build().values():
            assert "\\u" not in text, "导出物里出现 Unicode 转义，端侧读起来会很痛苦"
            json.loads(text)  # 仍然必须是合法 JSON

    def test_contract_version_is_required_not_defaulted(self) -> None:
        """``schema_version`` 必须必填。

        一旦给了默认值，陈旧的客户端漏传时会被静默当作「当前版本」处理，
        而它很可能正是版本不匹配的那一个 —— 那种错误会一路拖到字段语义
        对不上时才暴露，那时已经很难回溯到"版本没传"这个根因了。
        """
        field = DecisionRequest.model_fields["schema_version"]
        assert field.is_required(), "schema_version 不应有默认值"
        assert SCHEMA_VERSION
