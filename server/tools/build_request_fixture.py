"""生成决策请求的跨语言一致性测试向量。

用法::

    python -m tools.build_request_fixture            # 重新生成
    python -m tools.build_request_fixture --check    # 只校验现有 fixture 是否同步

**为什么需要这个**

``server/app/adapter.py`` 是「领域层判定结果 → 决策契约」的参考实现，
Dart 侧的 ``app/lib/app/decision_request.dart`` 必须与它逐字段一致。两边各有
完整测试，但**接缝本身**没有覆盖 —— 而接缝上的错误全都不会报错：

- 字段名对不上 → 服务端读到一个不存在的键，拿到默认值
- 序号基准不同（0-based / 1-based）→ 报告指着不存在的那一次
- 单位不一致（毫秒 / 秒）→ 数值看着合理，判定错得很像真的
- 一侧留空另一侧填 0 → 「不知道」被伪装成「零」

因此这里以 **Python 实现为参考基准**产出期望请求，Dart 端必须复现它。

**关于循环论证**，与 ``build_fixtures.py`` 是同一套说辞：要锁定的不是
「这份请求在体育上是否正确」（那由阈值核定与人工复核保证），而是
「两种语言是否给出同一个请求」。参考实现一旦冻结，它就是契约。

**场景为什么要跑完整条流水线**

因为端侧拿不到「已经调好个体化偏移的引擎」：Dart 的 ``ActionRunner`` 刻意不接
``config`` / 偏移参数，它自己从标定算出偏移。所以两侧都只能
「标定 → 建 runner → 喂帧 → finishSet」走一遍，fixture 里的帧序列因此是
**原始姿态**而不是特征值 —— 顺带把状态机与相位切分也纳入了跨语言比对。

代价是这条测试同时依赖跟踪器在两侧一致。那正是一条值得存在的依赖：
它在真实链路上，不在旁路上。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = REPO_ROOT / "shared" / "fixtures" / "decision_request_conformance.json"

FIXTURE_VERSION = "1.0"
FRAME_WIDTH = 720
FRAME_HEIGHT = 1280
FRAME_INTERVAL_MS = 33
ROUND_DIGITS = 6

THRESHOLDS_VERSION = "conformance-1"

#: 与端侧产品一致的机位。**不能改成 sagittal** —— 那样 fixture 通过而产品跑在
#: 另一个机位下，特征可用性（哪些特征在该机位下参与判定）就完全没有覆盖。
CAMERA_VIEW = "oblique45"

#: 合成姿态的几何。侧视：人面朝图像右侧，左右肢体在 x 上几乎重合。
#: 与 ``domain/tests/test_exercises.py`` 里那份同源 —— 三份几何（Python 测试、
#: Dart 测试、这里）各自服务不同的层级，但描述的是同一个动作。
_STANDING_JOINTS = {
    "HIP": (0.500, 0.450),
    "KNEE": (0.500, 0.680),
    "ANKLE": (0.500, 0.900),
}
_DEEP_JOINTS = {
    "HIP": (0.440, 0.700),
    "KNEE": (0.520, 0.700),
    "ANKLE": (0.520, 0.900),
}

#: 未显式给出的关键点（脸、眼、手等）统一放这里：可见、两两不重合。
_FILL = (0.505, 0.100)

#: 标定用帧数。必须 >= ``Calibrator.min_frames``（15），留些余量。
CALIBRATION_FRAMES = 20

#: 一次深蹲的分段帧数。每段都要够长 —— 状态机有投票窗口（5 帧）与最短停留（3 帧），
#: 一两帧的脉冲还没提交就过去了。
_SEGMENT = {"descent": 14, "bottom": 8, "ascent": 14, "settle": 10}


def _lerp(a: tuple[float, float], b: tuple[float, float], t: float) -> tuple[float, float]:
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def _squat_points(bend: float) -> dict[str, tuple[float, float]]:
    """一帧侧视深蹲姿态。``bend`` 从 0（直立）到 1（大腿平行地面）。"""
    hip = _lerp(_STANDING_JOINTS["HIP"], _DEEP_JOINTS["HIP"], bend)
    knee = _lerp(_STANDING_JOINTS["KNEE"], _DEEP_JOINTS["KNEE"], bend)
    ankle = _lerp(_STANDING_JOINTS["ANKLE"], _DEEP_JOINTS["ANKLE"], bend)

    shoulder_y = hip[1] - 0.23  # 肩随髋下沉，躯干保持竖直（本场景不构造前倾缺陷）
    heel_y = 0.922  # 脚跟脚尖均贴地 → 站立时 heel_rise_ratio ≈ 0

    return {
        "LEFT_HIP": hip,
        "RIGHT_HIP": hip,
        "LEFT_KNEE": knee,
        "RIGHT_KNEE": knee,
        "LEFT_ANKLE": ankle,
        "RIGHT_ANKLE": ankle,
        "LEFT_SHOULDER": (hip[0] - 0.002, shoulder_y),
        "RIGHT_SHOULDER": (hip[0] + 0.002, shoulder_y),
        "LEFT_HEEL": (ankle[0] - 0.018, heel_y),
        "RIGHT_HEEL": (ankle[0] + 0.002, heel_y),
        "LEFT_FOOT_INDEX": (ankle[0] + 0.025, heel_y),
        "RIGHT_FOOT_INDEX": (ankle[0] + 0.027, heel_y),
        "LEFT_ELBOW": (hip[0] - 0.010, shoulder_y + 0.110),
        "RIGHT_ELBOW": (hip[0] + 0.006, shoulder_y + 0.110),
        "LEFT_WRIST": (hip[0] - 0.018, shoulder_y + 0.210),
        "RIGHT_WRIST": (hip[0] + 0.014, shoulder_y + 0.210),
    }


def _scenario() -> list[float]:
    """本组动作的逐帧弯曲程度。

    **两次深蹲的深度刻意不同**：第一次蹲到位，第二次明显不够。这样 fixture 里
    既有「有错误的 rep」也有「没错误的 rep」，``fault_stats.reps`` 才能验出
    「只有第二次」—— 而那正是 0-based / 1-based 会分叉的地方。

    两个峰值是按实测膝角挑的（见下），不是随手取的整数：

    - ``1.00`` → 膝角 90°，低于深度线 100° → 这一组干净
    - ``0.90`` → 膝角 119.6°，高出深度线近 20° → 稳稳判出深度不足

    两者都远低于分段线（站立 180 − minBend 45 = 135°），所以**两次都会被计数** ——
    这是关键：蹲得太浅会连 rep 都不算，那样 ``fault_stats`` 是空的，
    「序号基准」这条就白测了。
    """
    bends: list[float] = [0.0] * CALIBRATION_FRAMES
    for peak in (1.00, 0.90):
        bends += [peak * i / _SEGMENT["descent"] for i in range(1, _SEGMENT["descent"] + 1)]
        bends += [peak] * _SEGMENT["bottom"]
        bends += [peak * i / _SEGMENT["ascent"] for i in range(_SEGMENT["ascent"], 0, -1)]
        bends += [0.0] * _SEGMENT["settle"]
    return bends


def _round(value: Any) -> Any:
    """递归地把浮点收成 ``ROUND_DIGITS`` 位。

    跨语言重实现很难逐位相同，而这里要抓的是「差了一个量级」「符号反了」
    「该是 null 却填了数」，不是最后一位 ulp。
    """
    if isinstance(value, float):
        return round(value, ROUND_DIGITS)
    if isinstance(value, dict):
        return {key: _round(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_round(item) for item in value]
    return value


def _render_frames(bends: list[float]) -> tuple[dict[str, list[float]], list[dict[str, Any]]]:
    """把弯曲序列渲染成「基准姿态 + 逐帧覆盖」。

    只输出与基准不同的点。33 点全量输出会让 fixture 大出三四倍，而多出来的
    全是不动的那十几个点 —— 读的人要在里面找真正在变的那几个。
    """
    base = {name: _FILL for name in _all_landmark_names()}
    base.update(_squat_points(0.0))

    frames: list[dict[str, Any]] = []
    ts = 1000  # 不能从 0 起：会话层把 timestampMs <= 0 当作「这帧没有时钟」
    for bend in bends:
        points = _squat_points(bend)
        overrides = {
            name: [round(x, 9), round(y, 9)]
            for name, (x, y) in points.items()
            if (x, y) != base[name]
        }
        frames.append({"timestamp_ms": ts, "overrides": overrides})
        ts += FRAME_INTERVAL_MS

    return {name: [round(x, 9), round(y, 9)] for name, (x, y) in base.items()}, frames


def _all_landmark_names() -> list[str]:
    from vitalteen_domain import L

    return [L(index).name for index in range(len(L))]


def _build_thresholds() -> Any:
    """一张已核定的阈值表。

    **刻意不用 ``shared/thresholds/`` 里那份真实阈值表**：那份全是
    ``pending_review``，只出提示、不驱动扣分，而 fixture 要覆盖的是完整路径。
    数值只为本 fixture 服务，不是体育判定依据。
    """
    from vitalteen_domain import SourceType, Threshold, ThresholdTable

    values = {
        "squat.min_depth_knee_angle": 100.0,
        "squat.knee_valgus_angle_notice": 10.0,
        "squat.trunk_lean_max_delta": 30.0,
        "squat.heel_rise_ratio_max_delta": 0.15,
        "squat.asymmetry_index_max": 0.10,
    }
    return ThresholdTable(
        [
            Threshold(
                key=key,
                action_code="SQUAT",
                feature_code="",
                value=value,
                unit="deg",
                source_type=SourceType.LITERATURE,
                version=THRESHOLDS_VERSION,
            )
            for key, value in values.items()
        ],
        version=THRESHOLDS_VERSION,
    )


def _run_pipeline() -> tuple[Any, Any, list[Any]]:
    """把帧序列喂进真实流水线，返回 ``(summary, engine, windows)``。

    走的是端侧会走的那条路：标定 → 建 runner → 逐帧 feed → finishSet。
    """
    from vitalteen_domain import Landmark, PoseFrame
    from vitalteen_domain.exercises import Calibrator, build_squat
    from vitalteen_domain.exercises.base import ActionRunner
    from vitalteen_domain.features import FeatureExtractor

    bends = _scenario()
    thresholds = _build_thresholds()
    extractor = FeatureExtractor(camera_view=CAMERA_VIEW)

    def pose(bend: float, ts: int) -> PoseFrame:
        points = {**_all_landmarks_fill(), **_squat_points(bend)}
        return PoseFrame(
            landmarks=tuple(
                Landmark(x=points[name][0], y=points[name][1], z=0.0, visibility=1.0)
                for name in _all_landmark_names()
            ),
            frame_width=FRAME_WIDTH,
            frame_height=FRAME_HEIGHT,
            timestamp_ms=ts,
        )

    calibrator = Calibrator()
    ts = 1000
    index = 0
    while not calibrator.is_ready and index < len(bends):
        calibrator.feed(extractor.extract(pose(bends[index], ts)))
        ts += FRAME_INTERVAL_MS
        index += 1

    calibration = calibrator.calibration
    if calibration is None:
        raise SystemExit("标定没有完成 —— 场景开头的站立帧不够")

    runner = ActionRunner(
        build_squat(calibration, camera_view=CAMERA_VIEW),
        thresholds=thresholds,
        calibration=calibration,
    )
    for bend in bends[index:]:
        runner.feed(pose(bend, ts))
        ts += FRAME_INTERVAL_MS

    return runner.finish_set(), runner.engine, runner.windows


def _all_landmarks_fill() -> dict[str, tuple[float, float]]:
    return {name: _FILL for name in _all_landmark_names()}


def build() -> dict[str, Any]:
    from app.adapter import build_request
    from app.contracts import DecisionContext, PoseQuality

    bends = _scenario()
    base_pose, frames = _render_frames(bends)
    summary, engine, windows = _run_pipeline()

    context = DecisionContext(
        sex="female",
        age=16,
        grade="高一",
        standard_group="高中女子",
        action_code="SQUAT",
        action_variant="standard",
        camera_view=CAMERA_VIEW,
        pose_backend="mlkit",
        has_world_landmarks=False,
    )
    pose_quality = PoseQuality(
        mean_visibility=0.94,
        coverage_ok_ratio=0.98,
        fps_mean=29.7,
        gap_max_ms=66,
        view_confidence=0.91,
    )

    request = build_request(
        summary,
        request_id="conformance-1",
        context=context,
        pose_quality=pose_quality,
        thresholds_version=THRESHOLDS_VERSION,
        windows=windows,
        engine=engine,
    )

    return {
        "fixture_version": FIXTURE_VERSION,
        "note": (
            "由 server/tools/build_request_fixture.py 生成。"
            "Dart 侧必须复现 expected_request —— 逐字段比对，见 "
            "app/test/app/decision_request_conformance_test.dart。"
        ),
        "camera_view": CAMERA_VIEW,
        "frame_width": FRAME_WIDTH,
        "frame_height": FRAME_HEIGHT,
        "calibration_frames": CALIBRATION_FRAMES,
        "base_pose": base_pose,
        "frames": frames,
        "thresholds": {
            "version": THRESHOLDS_VERSION,
            "action_code": "SQUAT",
            "values": {
                "squat.min_depth_knee_angle": 100.0,
                "squat.knee_valgus_angle_notice": 10.0,
                "squat.trunk_lean_max_delta": 30.0,
                "squat.heel_rise_ratio_max_delta": 0.15,
                "squat.asymmetry_index_max": 0.10,
            },
        },
        "context": {
            "sex": "female",
            "age": 16,
            "grade": "高一",
            "standard_group": "高中女子",
        },
        "pose_quality": {
            "mean_visibility": 0.94,
            "coverage_ok_ratio": 0.98,
            "fps_mean": 29.7,
            "gap_max_ms": 66,
            "view_confidence": 0.91,
        },
        "expected_request": _round(request.model_dump(mode="json")),
    }


def _dump(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="生成决策请求的跨语言一致性测试向量")
    parser.add_argument(
        "--check",
        action="store_true",
        help="仅校验现有 fixture 是否与当前实现同步，不写入",
    )
    args = parser.parse_args()

    payload = build()
    rendered = _dump(payload)

    if args.check:
        if not FIXTURE_PATH.exists():
            print(f"fixture 不存在：{FIXTURE_PATH}", file=sys.stderr)
            return 1
        if FIXTURE_PATH.read_text(encoding="utf-8") != rendered:
            print(
                "fixture 与当前实现不同步。\n"
                "若这是有意的行为变更，请运行 `python -m tools.build_request_fixture` "
                "重新生成，并同时确认 Dart 侧跟上；若是意外漂移，说明适配器有 bug。",
                file=sys.stderr,
            )
            return 1
        print(f"fixture 与实现同步：{FIXTURE_PATH}")
        return 0

    FIXTURE_PATH.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE_PATH.write_text(rendered, encoding="utf-8")
    request = payload["expected_request"]
    print(
        f"已写入 {FIXTURE_PATH}\n"
        f"  帧数 {len(payload['frames'])}，"
        f"rep 数 {request['set']['rep_count']}，"
        f"候选错误码 {[c['code'] for c in request['candidates']]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
