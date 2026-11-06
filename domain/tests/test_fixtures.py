"""跨语言一致性测试 —— Python 参考实现必须复现 golden fixtures。

这是设计文档 §8 在 Python 侧的守卫。Dart 端侧必须通过**同一份 fixture**，
因此这些测试同时定义了端侧实现的契约。

若本文件失败：

- 若你刚改过特征实现 → 先判断这是有意的行为变更还是 bug
- 有意变更 → 运行 ``python -m tools.build_fixtures`` 重新生成，并在提交信息里说明
- 意外漂移 → 是 bug，改回去

**刻意不 import ``tools.build_fixtures``**：若测试与生成器共用同一份构造代码，
构造逻辑本身出错时两边会一起错，测试就失去意义。这里独立重写一遍场景重建，
让「重建」也成为被验证的一环。
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from vitalteen_domain import (
    FEATURE_SPECS,
    N_LANDMARKS,
    FeatureExtractor,
    L,
    Landmark,
    PoseFrame,
)

FIXTURE_PATH = (
    Path(__file__).resolve().parents[2] / "shared" / "fixtures" / "feature_conformance.json"
)

#: 浮点比对容差。fixture 保留 6 位小数，跨语言重实现很难做到逐位相同，
#: 因此用绝对容差；关键是要抓住「差了一个量级」「符号反了」「该是 null 却填了数」。
TOLERANCE = 1e-4

#: 未显式给出的关键点统一填这里（脸、手、眼等，不影响本项目的特征）
_FILLER = (0.505, 0.100)

#: 侧视站立基准姿态。必须与 ``tools/build_fixtures.py`` 的 ``_STANDING`` 保持一致。
_STANDING: dict[str, tuple[float, float]] = {
    "NOSE": (0.510, 0.100),
    "LEFT_SHOULDER": (0.498, 0.220),
    "RIGHT_SHOULDER": (0.502, 0.220),
    "LEFT_HIP": (0.498, 0.450),
    "RIGHT_HIP": (0.502, 0.450),
    "LEFT_KNEE": (0.500, 0.680),
    "RIGHT_KNEE": (0.502, 0.680),
    "LEFT_ANKLE": (0.500, 0.900),
    "RIGHT_ANKLE": (0.502, 0.900),
    "LEFT_HEEL": (0.482, 0.922),
    "RIGHT_HEEL": (0.484, 0.922),
    "LEFT_FOOT_INDEX": (0.525, 0.922),
    "RIGHT_FOOT_INDEX": (0.527, 0.922),
    "LEFT_ELBOW": (0.470, 0.330),
    "RIGHT_ELBOW": (0.474, 0.330),
    "LEFT_WRIST": (0.462, 0.430),
    "RIGHT_WRIST": (0.466, 0.430),
}


def _load() -> dict | None:
    if not FIXTURE_PATH.exists():
        return None
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


def _scenario_ids() -> list[str]:
    data = _load()
    return [] if data is None else [s["id"] for s in data["scenarios"]]


@pytest.fixture(scope="module")
def conformance() -> dict:
    data = _load()
    if data is None:
        pytest.fail(f"fixture 缺失：{FIXTURE_PATH}\n请先运行 `python -m tools.build_fixtures`。")
    return data


def _build_pose(scenario: dict, frame_width: int, frame_height: int) -> PoseFrame:
    """按场景描述重建一帧姿态。"""
    base = dict(_STANDING)
    base.update({k: tuple(v) for k, v in scenario.get("overrides", {}).items()})  # type: ignore[misc]
    if scenario.get("mirrored"):
        base = {k: (1.0 - x, y) for k, (x, y) in base.items()}

    occluded_vis = scenario.get("occluded_landmark_visibility")

    landmarks: list[Landmark] = []
    for i in range(N_LANDMARKS):
        name = L(i).name
        x, y = base.get(name, _FILLER)
        vis = occluded_vis if (occluded_vis is not None and name == "LEFT_KNEE") else 1.0
        landmarks.append(Landmark(x=x, y=y, z=0.0, visibility=vis))

    return PoseFrame(
        landmarks=tuple(landmarks),
        frame_width=frame_width,
        frame_height=frame_height,
        timestamp_ms=0,
    )


def test_fixture_file_exists() -> None:
    assert FIXTURE_PATH.exists(), f"fixture 缺失：{FIXTURE_PATH}"


def test_fixture_covers_every_registered_feature(conformance: dict) -> None:
    """fixture 必须覆盖全部已注册特征，否则新增特征会悄悄逃过契约。"""
    declared = set(conformance["feature_codes"])
    registered = {spec.code for spec in FEATURE_SPECS}
    assert declared == registered, (
        f"fixture 与特征注册表不一致：缺少 {sorted(registered - declared)}，"
        f"多出 {sorted(declared - registered)}"
    )
    for scenario in conformance["scenarios"]:
        assert set(scenario["expected"]) == registered, (
            f"场景 {scenario['id']} 的期望值不完整"
        )


def test_fixture_has_enough_scenarios(conformance: dict) -> None:
    assert len(conformance["scenarios"]) >= 5, "场景过少，覆盖不足"


@pytest.mark.parametrize("scenario_id", _scenario_ids())
def test_reference_matches_fixture(conformance: dict, scenario_id: str) -> None:
    """逐个场景比对：参考实现必须复现 fixture 中的每一个期望值。"""
    scenario = next(s for s in conformance["scenarios"] if s["id"] == scenario_id)
    frame = _build_pose(scenario, conformance["frame_width"], conformance["frame_height"])
    features = FeatureExtractor(camera_view=scenario["camera_view"]).extract(frame)

    mismatches: list[str] = []
    for code, expected in scenario["expected"].items():
        actual = features.get(code)
        if expected is None:
            if actual is not None:
                mismatches.append(f"{code}: 期望不可用(null)，实际 {actual:.6f}")
        elif actual is None:
            reason = features.values[code].invalid_reason
            mismatches.append(f"{code}: 期望 {expected:.6f}，实际不可用({reason})")
        elif abs(actual - expected) > TOLERANCE:
            mismatches.append(f"{code}: 期望 {expected:.6f}，实际 {actual:.6f}")

    assert not mismatches, f"场景 {scenario_id} 与 fixture 不符：\n  " + "\n  ".join(mismatches)


def test_null_is_part_of_the_contract(conformance: dict) -> None:
    """``null`` 也是契约的一部分。

    不可用的特征必须两边都为 ``None``，不允许一边填 0、一边填 None ——
    这正是设计文档铁律二要防的事。
    """
    nulls = {
        (s["id"], code)
        for s in conformance["scenarios"]
        for code, expected in s["expected"].items()
        if expected is None
    }
    assert nulls, "fixture 中没有任何 null 期望值，说明可用性契约没有被覆盖"

    codes = {code for _, code in nulls}
    assert "knee_angle_L" in codes, "遮挡场景应当让 knee_angle_L 不可用"
    assert "frontal_knee_angle_L" in codes, "机位不匹配应当让额状面特征不可用"
    assert "heel_rise_ratio_L" in codes, "正视机位应当让脚跟抬升不可用"
