"""共享测试夹具。

请求构造器集中在这里，避免每个测试文件各写一份 —— 契约一旦演进（加字段、改枚举），
散落的构造器会有一部分忘记更新，于是那些测试**继续用旧结构跑并且通过**，
而它们本该因为结构不合法而失败。测试的假绿比没有测试更糟。
"""

from __future__ import annotations

from typing import Any

import pytest

from app.contracts import SCHEMA_VERSION, DecisionRequest


def _base_payload() -> dict[str, Any]:
    """一次真实的深蹲决策请求：10 次完成、8 次有效，膝内扣与深度不足各若干次。"""
    return {
        "request_id": "dec_20261003_0001",
        "schema_version": SCHEMA_VERSION,
        "context": {
            "sex": "male",
            "age": 14,
            "grade": "初中三年级",
            "standard_group": "初中-男",
            "action_code": "SQUAT",
            "action_variant": "bodyweight",
            "camera_view": "sagittal",
            "pose_backend": "mlkit",
            "has_world_landmarks": False,
        },
        "pose_quality": {
            "mean_visibility": 0.93,
            "coverage_ok_ratio": 0.98,
            "fps_mean": 28.4,
            "gap_max_ms": 180,
            "view_confidence": 0.91,
        },
        "set": {
            "rep_count": 10,
            "valid_rep_count": 8,
            "tempo_mean_ms": 2850.0,
            "rom_mean_deg": 88.5,
            "symmetry_index_mean": 0.04,
            "fault_stats": [
                {"code": "KNEE_VALGUS", "reps": [2, 5, 7], "count": 3},
                {"code": "INSUFFICIENT_DEPTH", "reps": [5, 9], "count": 2},
            ],
        },
        "reps": [
            {
                "index": 2,
                "duration_ms": 2900,
                "phases_ms": {"descent": 420, "bottom": 1480, "ascent": 1000},
                "metrics": {"knee_angle_bottom_deg": 92.3},
                "faults": [
                    {
                        "code": "KNEE_VALGUS",
                        "confidence": 0.83,
                        "evidence_frames": [1042, 1044],
                        "deviations": [
                            {
                                "feature": "frontal_knee_angle_max",
                                "measured": 13.6,
                                "threshold": 10.0,
                                "delta_signed": 3.6,
                                "severity_0_1": 0.62,
                            }
                        ],
                    }
                ],
                "confidence": 0.91,
            },
            {
                "index": 5,
                "duration_ms": 3100,
                "phases_ms": {"descent": 500, "bottom": 1600, "ascent": 1000},
                "metrics": {"knee_angle_bottom_deg": 108.4},
                "faults": [
                    {
                        "code": "INSUFFICIENT_DEPTH",
                        "confidence": 0.88,
                        "evidence_frames": [2100],
                        "deviations": [
                            {
                                "feature": "knee_angle_L",
                                "measured": 108.4,
                                "threshold": 95.0,
                                "delta_signed": 13.4,
                                "severity_0_1": 0.34,
                            }
                        ],
                    }
                ],
                "confidence": 0.89,
            },
        ],
        "candidates": [
            {"code": "KNEE_VALGUS", "triggered_by_rule": "FRONTAL_KNEE_MAX > T_VALGUS"},
            {"code": "INSUFFICIENT_DEPTH", "triggered_by_rule": "KNEE_BOTTOM_MIN > T_DEPTH"},
        ],
        "thresholds_version": "thr_2026-10_v1",
    }


@pytest.fixture
def request_factory():
    """返回一个构造 :class:`DecisionRequest` 的工厂。

    用法::

        def test_x(request_factory):
            request = request_factory(set={"rep_count": 0, "valid_rep_count": 0})
    """

    def _make(*, _drop: tuple[str, ...] = (), **overrides: Any) -> DecisionRequest:
        payload = _base_payload()
        for key in _drop:
            payload.pop(key, None)
        payload.update(overrides)
        return DecisionRequest.model_validate(payload)

    return _make


@pytest.fixture
def sample_request(request_factory) -> DecisionRequest:
    """一份标准的深蹲决策请求。"""
    return request_factory()


@pytest.fixture
def raw_payload() -> dict[str, Any]:
    """原始字典形态，供需要绕过模型校验（测非法输入）的测试使用。"""
    return _base_payload()
