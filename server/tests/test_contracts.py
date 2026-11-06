"""决策契约测试。

契约是三方（手机端 / 决策服务 / 大屏与报告）的共同边界，因此这里的测试重点不是
「字段能不能填」，而是**边界条件下的拒绝行为**：契约的价值在于把不一致挡在入口，
一个来者不拒的契约等于没有契约。
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from pydantic import ValidationError

from app.contracts import (
    MAX_CANDIDATES,
    SCHEMA_VERSION,
    CandidateIn,
    DecisionContext,
    DecisionFault,
    DecisionMeta,
    DecisionRequest,
    DecisionResponse,
    FaultEvidence,
    FaultRef,
    FaultStatIn,
    PoseQuality,
    Scores,
    SetIn,
)


def make_context(**overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "sex": "male",
        "age": 14,
        "grade": "初中三年级",
        "standard_group": "初中-男",
        "action_code": "SQUAT",
        "action_variant": "bodyweight",
        "camera_view": "sagittal",
        "pose_backend": "mlkit",
        "has_world_landmarks": False,
    }
    base.update(overrides)
    return base


def make_quality(**overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "mean_visibility": 0.93,
        "coverage_ok_ratio": 0.98,
        "fps_mean": 28.4,
        "gap_max_ms": 180,
        "view_confidence": 0.91,
    }
    base.update(overrides)
    return base


def make_set(**overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "rep_count": 10,
        "valid_rep_count": 8,
        "tempo_mean_ms": 2850.0,
        "rom_mean_deg": 88.5,
        "symmetry_index_mean": 0.04,
        "fault_stats": [
            {"code": "KNEE_VALGUS", "reps": [2, 5, 7], "count": 3},
            {"code": "INSUFFICIENT_DEPTH", "reps": [5, 9], "count": 2},
        ],
    }
    base.update(overrides)
    return base


def make_request(**overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "request_id": "dec_20261003_0001",
        "schema_version": SCHEMA_VERSION,
        "context": make_context(),
        "pose_quality": make_quality(),
        "set": make_set(),
        "reps": [],
        "candidates": [
            {"code": "KNEE_VALGUS", "triggered_by_rule": "VALGUS_MAX > T"},
            {"code": "INSUFFICIENT_DEPTH", "triggered_by_rule": "DEPTH_MIN > T"},
        ],
        "thresholds_version": "thr_2026-10_v1",
    }
    base.update(overrides)
    return base


class TestDecisionRequest:
    def test_minimal_valid_request(self) -> None:
        request = DecisionRequest.model_validate(make_request())
        assert request.schema_version == SCHEMA_VERSION
        assert request.context.action_code == "SQUAT"
        assert request.thresholds_version == "thr_2026-10_v1"

    def test_unknown_field_is_rejected(self) -> None:
        """多出未声明字段必须报错。

        静默忽略会让「端侧发了新字段、服务端还在用旧逻辑」一直藏着，
        直到某个结果明显不对才被发现 —— 那时已经很难回溯是谁先不同步的。
        """
        payload = make_request()
        payload["context"]["future_field"] = "something"
        with pytest.raises(ValidationError, match="future_field"):
            DecisionRequest.model_validate(payload)

    def test_thresholds_version_is_required(self) -> None:
        """没有阈值版本就无法复现一个历史决策 —— 阈值可能已经升版了。"""
        payload = make_request()
        del payload["thresholds_version"]
        with pytest.raises(ValidationError):
            DecisionRequest.model_validate(payload)

    @pytest.mark.parametrize("age", [4, 26])
    def test_age_out_of_range_is_rejected(self, age: int) -> None:
        payload = make_request()
        payload["context"]["age"] = age
        with pytest.raises(ValidationError):
            DecisionRequest.model_validate(payload)


class TestCandidateLimit:
    def test_candidates_at_limit_are_accepted(self) -> None:
        payload = make_request()
        payload["candidates"] = [
            {"code": f"FAULT_{i:02d}", "triggered_by_rule": "r"} for i in range(MAX_CANDIDATES)
        ]
        assert len(DecisionRequest.model_validate(payload).candidates) == MAX_CANDIDATES

    def test_candidates_over_limit_are_rejected(self) -> None:
        """Laya 在选项数超过约 20 后准确率急剧下降，因此上限是硬约束而不是建议。"""
        payload = make_request()
        payload["candidates"] = [
            {"code": f"FAULT_{i:02d}", "triggered_by_rule": "r"} for i in range(MAX_CANDIDATES + 1)
        ]
        with pytest.raises(ValidationError, match="候选集"):
            DecisionRequest.model_validate(payload)

    def test_duplicate_candidate_codes_are_rejected(self) -> None:
        """重复候选会让「选中的是哪一项」变得有歧义。"""
        payload = make_request()
        payload["candidates"] = [
            {"code": "KNEE_VALGUS", "triggered_by_rule": "a"},
            {"code": "KNEE_VALGUS", "triggered_by_rule": "b"},
        ]
        with pytest.raises(ValidationError, match="重复"):
            DecisionRequest.model_validate(payload)


class TestSetConsistency:
    def test_valid_rep_count_cannot_exceed_total(self) -> None:
        payload = make_request()
        payload["set"] = make_set(rep_count=5, valid_rep_count=6)
        with pytest.raises(ValidationError, match="valid_rep_count"):
            DecisionRequest.model_validate(payload)

    def test_fault_count_must_match_reps_length(self) -> None:
        payload = make_request()
        payload["set"] = make_set(fault_stats=[{"code": "X", "reps": [1, 2], "count": 3}])
        with pytest.raises(ValidationError, match="count"):
            DecisionRequest.model_validate(payload)

    def test_zero_rep_set_is_valid(self) -> None:
        """「一个都没做出来」是合法状态，必须能被表达，而不是被当成错误数据。"""
        payload = make_request()
        payload["set"] = make_set(rep_count=0, valid_rep_count=0, fault_stats=[])
        assert DecisionRequest.model_validate(payload).set.rep_count == 0

    def test_optional_metrics_may_be_absent(self) -> None:
        payload = make_request()
        payload["set"] = make_set(tempo_mean_ms=None, rom_mean_deg=None, symmetry_index_mean=None)
        request = DecisionRequest.model_validate(payload)
        assert request.set.rom_mean_deg is None


class TestDecisionResponse:
    def make_fault(self, **overrides: Any) -> dict[str, Any]:
        base: dict[str, Any] = {
            "code": "KNEE_VALGUS",
            "name": "膝内扣",
            "severity_level": 2,
            "severity_score": 58,
            "confidence": 0.82,
            "evidence": {"reps": [2, 5, 7], "metric": "frontal_knee_angle_max"},
        }
        base.update(overrides)
        return base

    def make_meta(self, **overrides: Any) -> dict[str, Any]:
        base: dict[str, Any] = {
            "decision_model_version": "laya-multilingual",
            "thresholds_version": "thr_2026-10_v1",
            "latency_ms": 96,
            "shuffled": True,
            "shuffle_seed": 42,
        }
        base.update(overrides)
        return base

    def make_response(self, **overrides: Any) -> dict[str, Any]:
        base: dict[str, Any] = {
            "request_id": "dec_20261003_0001",
            "status": "ok",
            "faults": [self.make_fault()],
            "gates": {"depth_ok": False, "valgus_ok": False, "heel_ok": True},
            "scores": {"form_score": 71, "rating": "中"},
            "meta": self.make_meta(),
        }
        base.update(overrides)
        return base

    def test_valid_response(self) -> None:
        response = DecisionResponse.model_validate(self.make_response())
        assert response.status == "ok"
        assert response.gates["heel_ok"] is True
        assert response.scores is not None and response.scores.form_score == 71

    def test_abstain_requires_reason(self) -> None:
        """弃权必须说明原因。宁可弃权也不编造确定性，但弃权本身也要可解释。"""
        payload = self.make_response(status="abstain", abstain_reason=None)
        with pytest.raises(ValidationError, match="abstain_reason"):
            DecisionResponse.model_validate(payload)

    def test_abstain_with_reason_is_valid(self) -> None:
        payload = self.make_response(status="abstain", abstain_reason="低置信度：关键点丢失过多")
        response = DecisionResponse.model_validate(payload)
        assert response.abstain_reason is not None

    def test_ok_must_not_carry_abstain_reason(self) -> None:
        payload = self.make_response(status="ok", abstain_reason="不该出现在这里")
        with pytest.raises(ValidationError, match="abstain_reason"):
            DecisionResponse.model_validate(payload)

    def test_primary_fault_must_appear_in_faults(self) -> None:
        payload = self.make_response(primary_fault={"code": "HEEL_RISE", "name": "脚跟离地"})
        with pytest.raises(ValidationError, match="primary_fault"):
            DecisionResponse.model_validate(payload)

    def test_primary_fault_that_exists_is_valid(self) -> None:
        payload = self.make_response(primary_fault={"code": "KNEE_VALGUS", "name": "膝内扣"})
        assert DecisionResponse.model_validate(payload).primary_fault is not None

    @pytest.mark.parametrize("level", [0, 4])
    def test_severity_level_out_of_range_is_rejected(self, level: int) -> None:
        payload = self.make_response(faults=[self.make_fault(severity_level=level)])
        with pytest.raises(ValidationError):
            DecisionResponse.model_validate(payload)

    @pytest.mark.parametrize("score", [-1, 101])
    def test_form_score_out_of_range_is_rejected(self, score: int) -> None:
        payload = self.make_response(scores={"form_score": score, "rating": "中"})
        with pytest.raises(ValidationError):
            DecisionResponse.model_validate(payload)

    def test_confidence_out_of_range_is_rejected(self) -> None:
        payload = self.make_response(faults=[self.make_fault(confidence=1.5)])
        with pytest.raises(ValidationError):
            DecisionResponse.model_validate(payload)

    def test_gates_accept_arbitrary_keys(self) -> None:
        """门控项随动作而不同（深蹲看深度，平板支撑看体线），因此键是开放的。"""
        payload = self.make_response(gates={"body_line_ok": True, "head_ok": False})
        assert DecisionResponse.model_validate(payload).gates == {
            "body_line_ok": True,
            "head_ok": False,
        }

    def test_empty_faults_is_valid(self) -> None:
        """「这组动作没发现问题」是合法结论，不能被当成数据缺失。"""
        payload = self.make_response(faults=[], scores={"form_score": 92, "rating": "优"})
        response = DecisionResponse.model_validate(payload)
        assert response.faults == []
        assert response.primary_fault is None


class TestSchemaExport:
    def test_json_schema_is_exportable(self) -> None:
        """契约要能被导出成 JSON Schema。

        导出物是给 Dart 端用的：端侧拿它做本地校验，就不必等发到服务端才知道字段拼错了。
        """
        schema = DecisionRequest.model_json_schema()
        assert schema["title"] == "DecisionRequest"
        assert "candidates" in schema["properties"]
        # 必须能被序列化，否则端侧拿不到
        assert json.dumps(schema, ensure_ascii=False)

    def test_response_schema_is_exportable(self) -> None:
        schema = DecisionResponse.model_json_schema()
        assert "gates" in schema["properties"]
        assert json.dumps(schema, ensure_ascii=False)

    def test_request_roundtrips_through_json(self) -> None:
        original = DecisionRequest.model_validate(make_request())
        restored = DecisionRequest.model_validate_json(original.model_dump_json())
        assert restored == original


class TestValueObjects:
    def test_context_requires_known_backend(self) -> None:
        with pytest.raises(ValidationError):
            DecisionContext.model_validate(make_context(pose_backend="opencv"))

    def test_quality_rejects_impossible_values(self) -> None:
        with pytest.raises(ValidationError):
            PoseQuality.model_validate(make_quality(mean_visibility=1.5))

    def test_plan_choice_caps_selected_ids(self) -> None:
        """最多给 3 个方案 —— 一次给十来个训练动作等于没给建议。"""
        from app.contracts import PlanChoice

        with pytest.raises(ValidationError):
            PlanChoice.model_validate({"selected_plan_ids": ["a", "b", "c", "d"]})

    def test_models_are_frozen_against_unknown_fields(self) -> None:
        with pytest.raises(ValidationError):
            SetIn.model_validate({**make_set(), "unknown": 1})
        with pytest.raises(ValidationError):
            Scores.model_validate({"form_score": 80, "rating": "良", "extra": 1})
        with pytest.raises(ValidationError):
            DecisionMeta.model_validate(
                {
                    "decision_model_version": "x",
                    "thresholds_version": "v",
                    "latency_ms": 1,
                    "nope": True,
                }
            )
        with pytest.raises(ValidationError):
            FaultStatIn.model_validate({"code": "X", "count": 0, "unexpected": 1})
        with pytest.raises(ValidationError):
            CandidateIn.model_validate({"code": "X", "triggered_by_rule": "r", "extra": 1})
        with pytest.raises(ValidationError):
            DecisionFault.model_validate(
                {
                    "code": "X",
                    "name": "x",
                    "severity_level": 1,
                    "severity_score": 1,
                    "confidence": 0.5,
                    "extra": 1,
                }
            )
        with pytest.raises(ValidationError):
            FaultRef.model_validate({"code": "X", "name": "x", "extra": 1})
        with pytest.raises(ValidationError):
            FaultEvidence.model_validate({"reps": [], "extra": 1})
