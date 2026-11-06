"""生成跨语言一致性测试向量（golden fixtures）。

用法::

    python -m tools.build_fixtures            # 重新生成
    python -m tools.build_fixtures --check    # 只校验现有 fixture 是否与实现同步

**为什么需要这个**

特征在 Python（生成训练数据）和 Dart（端侧推理）中各实现一次。若两者算出的
数值存在细微差异，模型会在训练时学到一套分布、推理时见到另一套，准确率静默
崩塌且极难定位 —— 这是本项目最隐蔽也最致命的一类 bug，详见
docs/domain-layer-design.md §8。

本脚本以 **Python 实现为参考基准**产出期望值。Dart 端必须复现这些数值。

**关于循环论证的说明**

「由实现生成期望值，再用期望值验证实现」看起来是循环的，但对**跨语言一致性**
这个目标不成立：这里要锁定的不是「数值是否物理正确」（那由体育专业成员核定阈值
与人工复核保证），而是「两种语言是否给出同一个数」。参考实现一旦冻结，它就是契约。

因此本脚本只负责产出机器可读的契约；**场景本身的物理合理性由人工审阅
SCENARIOS 表保证**，所以场景定义写在下面这份可读的 Python 里，而不是让人去
直接改 JSON。

`--check` 模式用于 CI：若实现改动导致输出漂移，它会失败并打印差异，
逼迫改动者显式确认这是有意的行为变更，而不是悄悄放过去。
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

from vitalteen_domain import FEATURE_SPECS, N_LANDMARKS, FeatureExtractor, L, Landmark, PoseFrame

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = REPO_ROOT / "shared" / "fixtures" / "feature_conformance.json"

FIXTURE_VERSION = "1.1"
FRAME_WIDTH = 720
FRAME_HEIGHT = 1280
ROUND_DIGITS = 6

#: 站立侧视基准姿态。人面朝图像右侧（脚尖指向 +x），左右肢体在 x 上几乎重合。
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

#: 未显式给出的关键点统一填这个位置（脸、手、眼等，不影响本项目的特征）
_FILLER = (0.505, 0.100)


@dataclass(frozen=True, slots=True)
class Scenario:
    """一个测试场景。

    Args:
        id: 稳定标识，Dart 端测试按此名索引。
        description: 中文说明。**写清楚这个场景在防什么回归** ——
            将来有人改动实现时，看到描述才知道能否安全地接受 fixture 变化。
        camera_view: 机位，决定哪些特征有定义。
        overrides: 在基准姿态上覆盖的关键点。
        mirror_x: 是否沿画面中线镜像（用于构造「人面朝左」的场景）。
        visibility: 关键点可见性；用于构造遮挡场景。
        expected_null: 断言这些特征必须为不可用（``None``）。
            显式列出比让测试从 fixture 里读出 ``null`` 更有诊断价值。
    """

    id: str
    description: str
    camera_view: str
    overrides: dict[str, tuple[float, float]] | None = None
    mirror_x: bool = False
    visibility: float = 1.0
    expected_null: tuple[str, ...] = ()


SCENARIOS: tuple[Scenario, ...] = (
    Scenario(
        id="standing_sagittal",
        description="侧视直立基准。膝角≈180、躯干倾角≈0、髋高出膝一个躯干长。",
        camera_view="sagittal",
    ),
    Scenario(
        id="squat_bottom_parallel",
        description=(
            "平行蹲最低点：大腿水平、膝角≈90。"
            "兼作倾角负零回归 —— 大腿向量是纯水平右向，修复前 thigh_tilt 会返回 -0.0。"
        ),
        camera_view="sagittal",
        overrides={
            "LEFT_HIP": (0.440, 0.700), "RIGHT_HIP": (0.440, 0.700),
            "LEFT_KNEE": (0.520, 0.700), "RIGHT_KNEE": (0.520, 0.700),
            "LEFT_ANKLE": (0.520, 0.900), "RIGHT_ANKLE": (0.520, 0.900),
            "LEFT_SHOULDER": (0.428, 0.450), "RIGHT_SHOULDER": (0.432, 0.450),
            "LEFT_HEEL": (0.502, 0.922), "RIGHT_HEEL": (0.504, 0.922),
            "LEFT_FOOT_INDEX": (0.545, 0.922), "RIGHT_FOOT_INDEX": (0.547, 0.922),
        },
    ),
    Scenario(
        id="squat_bottom_parallel_facing_left",
        description=(
            "与上一条几何相同，但人面朝图像左侧（整体镜像）。"
            "锁定倾角函数的象限与负零行为 —— 修复前纯左向向量会返回 -180.0，"
            "落在 docstring 声明的 (-180, 180] 之外。"
        ),
        camera_view="sagittal",
        overrides={
            "LEFT_HIP": (0.440, 0.700), "RIGHT_HIP": (0.440, 0.700),
            "LEFT_KNEE": (0.520, 0.700), "RIGHT_KNEE": (0.520, 0.700),
            "LEFT_ANKLE": (0.520, 0.900), "RIGHT_ANKLE": (0.520, 0.900),
            "LEFT_SHOULDER": (0.428, 0.450), "RIGHT_SHOULDER": (0.432, 0.450),
            "LEFT_HEEL": (0.502, 0.922), "RIGHT_HEEL": (0.504, 0.922),
            "LEFT_FOOT_INDEX": (0.545, 0.922), "RIGHT_FOOT_INDEX": (0.547, 0.922),
        },
        mirror_x=True,
    ),
    Scenario(
        id="squat_bottom_shallow",
        description=(
            "浅蹲最低点：膝角≈169，用于验证「下蹲深度不足」规则会命中。"
            "与 squat_bottom_parallel 构成对照。"
        ),
        camera_view="sagittal",
        overrides={
            "LEFT_HIP": (0.460, 0.550), "RIGHT_HIP": (0.460, 0.550),
            "LEFT_KNEE": (0.505, 0.680), "RIGHT_KNEE": (0.505, 0.680),
            "LEFT_ANKLE": (0.505, 0.900), "RIGHT_ANKLE": (0.505, 0.900),
            "LEFT_SHOULDER": (0.448, 0.300), "RIGHT_SHOULDER": (0.452, 0.300),
            "LEFT_HEEL": (0.487, 0.922), "RIGHT_HEEL": (0.489, 0.922),
            "LEFT_FOOT_INDEX": (0.530, 0.922), "RIGHT_FOOT_INDEX": (0.532, 0.922),
        },
    ),
    Scenario(
        id="standing_asymmetric_knee",
        description=(
            "直立但右膝前移。锁定「左右侧特征各自独立、不串用关键点」—— "
            "若实现里左右腿误用了同一组关键点，左膝角会跟着一起变，本场景专门抓这个。"
        ),
        camera_view="sagittal",
        overrides={"RIGHT_KNEE": (0.560, 0.680)},
    ),
    Scenario(
        id="standing_frontal_valgus",
        description=(
            "正视、两腿分开而**两膝内扣**（膝点从髋-踝连线向内偏，额状面膝角≈12.7）。"
            "与 standing_frontal_straddle 是**同一副站姿、只差膝的位置**，"
            "两者构成一对 12.7° 对 0° 的对照 —— 开合跳的「落地膝内扣」判定"
            "问的正是这个量，而没有这一对的话，把方向写反（腿越直越算内扣）"
            "在 fixture 上完全看不出来。"
            "它同时锁定「额状面膝角在正视下可用、而依赖侧视的特征在正视下必须判为"
            "机位不匹配」。**改这组数之前先读 `jj.dart` 的规则方向。**"
        ),
        camera_view="frontal",
        overrides={
            "LEFT_SHOULDER": (0.44, 0.220), "RIGHT_SHOULDER": (0.56, 0.220),
            "LEFT_ELBOW": (0.42, 0.330), "RIGHT_ELBOW": (0.58, 0.330),
            "LEFT_WRIST": (0.40, 0.430), "RIGHT_WRIST": (0.60, 0.430),
            "LEFT_HIP": (0.470, 0.450), "RIGHT_HIP": (0.530, 0.450),
            # 膝点朝中线挪：左膝 0.425→0.470、右膝 0.575→0.530。
            "LEFT_KNEE": (0.470, 0.675), "RIGHT_KNEE": (0.530, 0.675),
            "LEFT_ANKLE": (0.380, 0.900), "RIGHT_ANKLE": (0.620, 0.900),
            "LEFT_HEEL": (0.380, 0.922), "RIGHT_HEEL": (0.620, 0.922),
            "LEFT_FOOT_INDEX": (0.340, 0.922), "RIGHT_FOOT_INDEX": (0.660, 0.922),
        },
        expected_null=("heel_rise_ratio_L", "heel_rise_ratio_R", "body_line_angle"),
    ),
    Scenario(
        id="standing_frontal_straddle",
        description=(
            "正视、两腿分开的站姿（肩宽 0.12、两踝间距 0.24，比值恰好 2.0）。"
            "锁定 `leg_spread_ratio` 的分子分母 —— 基准姿态里两者是 0.004 与 0.002，"
            "比值 0.5 是个太圆的数，分子分母写反、漏除肩宽、或忘了取绝对值"
            "都未必看得出来。膝点取在髋-踝连线上，所以额状面膝角≈0，"
            "给「没有内扣」留一个干净参照。"
        ),
        camera_view="frontal",
        overrides={
            "LEFT_SHOULDER": (0.44, 0.220), "RIGHT_SHOULDER": (0.56, 0.220),
            "LEFT_ELBOW": (0.42, 0.330), "RIGHT_ELBOW": (0.58, 0.330),
            "LEFT_WRIST": (0.40, 0.430), "RIGHT_WRIST": (0.60, 0.430),
            "LEFT_HIP": (0.470, 0.450), "RIGHT_HIP": (0.530, 0.450),
            "LEFT_KNEE": (0.425, 0.675), "RIGHT_KNEE": (0.575, 0.675),
            "LEFT_ANKLE": (0.380, 0.900), "RIGHT_ANKLE": (0.620, 0.900),
            "LEFT_HEEL": (0.380, 0.922), "RIGHT_HEEL": (0.620, 0.922),
            "LEFT_FOOT_INDEX": (0.340, 0.922), "RIGHT_FOOT_INDEX": (0.660, 0.922),
        },
        expected_null=("heel_rise_ratio_L", "heel_rise_ratio_R", "body_line_angle"),
    ),
    Scenario(
        id="standing_frontal_one_arm_low",
        description=(
            "正视，右臂举过头顶、左臂垂在体侧。锁定 `shoulder_angle_min` 取的是"
            "**小**的那一侧 —— 基准姿态两臂对称，min 与 max 相等，把实现换成取大者"
            "也照样对得上；只有两臂角度明显不同（这里约 9° 对约 171°）才分得开。"
            "这一条直接决定开合跳「手臂上举幅度不足」会不会因为一侧举得高就放过。"
        ),
        camera_view="frontal",
        overrides={
            "RIGHT_ELBOW": (0.520, 0.100),
            "RIGHT_WRIST": (0.530, 0.020),
        },
    ),
    Scenario(
        id="standing_oblique45",
        description=(
            "斜前 45 度机位。用于锁定机位集合的边界："
            "斜视下额状面特征仍应不可用，而脚跟抬升可用。"
        ),
        camera_view="oblique45",
        expected_null=("frontal_knee_angle_L", "frontal_knee_angle_R", "pelvis_offset_ratio"),
    ),
    Scenario(
        id="standing_occluded_knee",
        description=(
            "左膝被遮挡（可见性 0.2，低于门控 0.5）。"
            "锁定铁律二：依赖该点的特征必须输出 null 并标注 low_visibility，"
            "**绝不允许填 0** —— 一个编造的 0 度膝角会被规则引擎当成「膝盖完全对折」。"
        ),
        camera_view="sagittal",
        overrides={"LEFT_KNEE": (0.500, 0.680)},
        visibility=0.2,
    ),
)


def _build_pose(scenario: Scenario) -> PoseFrame:
    pts = dict(_STANDING)
    if scenario.overrides:
        pts.update(scenario.overrides)
    if scenario.mirror_x:
        pts = {k: (1.0 - x, y) for k, (x, y) in pts.items()}

    landmarks: list[Landmark] = []
    for i in range(N_LANDMARKS):
        name = L(i).name
        x, y = pts.get(name, _FILLER)
        vis = scenario.visibility if name == "LEFT_KNEE" else 1.0
        landmarks.append(Landmark(x=x, y=y, z=0.0, visibility=vis))
    return PoseFrame(
        landmarks=tuple(landmarks),
        frame_width=FRAME_WIDTH,
        frame_height=FRAME_HEIGHT,
        timestamp_ms=0,
    )


def _round(value: float | None) -> float | None:
    return None if value is None else round(value, ROUND_DIGITS)


def build() -> dict:
    payload: dict = {
        "fixture_version": FIXTURE_VERSION,
        "generated_by": "domain/tools/build_fixtures.py",
        "frame_width": FRAME_WIDTH,
        "frame_height": FRAME_HEIGHT,
        "feature_codes": [spec.code for spec in FEATURE_SPECS],
        # 基准姿态随 fixture 一起发布，且必须是**完整的 33 点**。
        #
        # 场景里的 overrides 是相对这份基准的覆盖，因此消费方必须知道基准是什么。
        # 只发布 _STANDING 里那 17 个点是**不够的** —— 剩下 16 个（眼、嘴、手）
        # 用的是生成器内部的填充常量，那不在 fixture 里。消费方就得去猜，
        # 而猜错时算出的特征会静默偏移 —— 正是这份 fixture 要防的事。
        "base_pose": {
            L(i).name: list(_STANDING.get(L(i).name, _FILLER)) for i in range(N_LANDMARKS)
        },
        "scenarios": [],
    }
    for scenario in SCENARIOS:
        frame = _build_pose(scenario)
        extractor = FeatureExtractor(camera_view=scenario.camera_view)  # type: ignore[arg-type]
        features = extractor.extract(frame)
        expected = {spec.code: _round(features.get(spec.code)) for spec in FEATURE_SPECS}

        missing = [code for code in scenario.expected_null if expected.get(code) is not None]
        if missing:
            raise SystemExit(
                f"场景 {scenario.id} 声明这些特征应为 null，实际有值：{missing}"
            )

        payload["scenarios"].append(
            {
                "id": scenario.id,
                "description": scenario.description,
                "camera_view": scenario.camera_view,
                "mirrored": scenario.mirror_x,
                "occluded_landmark_visibility": (
                    scenario.visibility if scenario.visibility < 1.0 else None
                ),
                "overrides": scenario.overrides or {},
                "expected": expected,
            }
        )
    return payload


def _dump(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="生成跨语言一致性测试向量")
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
        existing = FIXTURE_PATH.read_text(encoding="utf-8")
        if existing != rendered:
            print(
                "fixture 与当前实现不同步。\n"
                "若这是有意的行为变更，请运行 `python -m tools.build_fixtures` 重新生成，"
                "并在提交信息里说明变化原因；若是意外漂移，说明实现有 bug。",
                file=sys.stderr,
            )
            return 1
        print(f"fixture 与实现同步：{FIXTURE_PATH}")
        return 0

    FIXTURE_PATH.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE_PATH.write_text(rendered, encoding="utf-8")
    print(f"已写入 {FIXTURE_PATH}（{len(SCENARIOS)} 个场景）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
