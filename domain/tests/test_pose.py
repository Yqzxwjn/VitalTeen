"""``vitalteen_domain.pose`` 姿态帧测试。

重点锁死的约定：

- ``PoseFrame.pixel()`` 是归一化坐标→像素坐标的**唯一入口**，必须按
  ``frame_width`` / ``frame_height`` **分别**折算 —— 宽高不等的画幅是本套件
  的默认场景（720×1280，竖屏）。
- ``landmarks`` 必须恰好 33 个；``frame_width`` / ``frame_height`` 必须为正。
- 无世界坐标时 ``world()`` 返回 ``None``（不是 0）；``has_world`` 与之配套。
- 可见性判定用 ``>=``：恰好等于阈值算可见。
- ``joint_angle`` / ``torso_length`` 一律在像素空间计算。
- ``frames_from_json()`` 支持 ``world_landmarks`` 为 ``null``。
"""

from __future__ import annotations

import pytest

from vitalteen_domain.geometry import DegenerateGeometryError
from vitalteen_domain.landmarks import N_LANDMARKS, L
from vitalteen_domain.pose import (
    Landmark,
    PoseFrame,
    PoseFrameError,
    frames_from_json,
    joint_angle,
)

# --------------------------------------------------------------- 辅助工厂


def make_world_landmarks(**overrides: tuple[float, float, float]) -> tuple[Landmark, ...]:
    """构造 33 个世界坐标点（米），默认全部为原点。"""
    points = [Landmark(x=0.0, y=0.0, z=0.0) for _ in range(N_LANDMARKS)]
    for name, (x, y, z) in overrides.items():
        points[L[name]] = Landmark(x=x, y=y, z=z)
    return tuple(points)


def make_frame(
    *,
    frame_width: int = 720,
    frame_height: int = 1280,
    timestamp_ms: int = 0,
    visibility: float = 1.0,
    world: tuple[Landmark, ...] | None = None,
    **overrides: tuple[float, float] | Landmark,
) -> PoseFrame:
    """构造一帧 33 点姿态帧。

    默认：所有点位于画面正中央 ``(0.5, 0.5)``、可见性 1.0、画幅 720×1280。
    ``overrides`` 的键为 :class:`~vitalteen_domain.landmarks.L` 的成员名
    （如 ``LEFT_KNEE``），值为 ``(x, y)`` 归一化坐标，或完整的
    :class:`Landmark`（用于单独修改可见性等字段）。
    """
    points = [Landmark(x=0.5, y=0.5, visibility=visibility) for _ in range(N_LANDMARKS)]
    for name, value in overrides.items():
        idx = L[name]
        if isinstance(value, Landmark):
            points[idx] = value
        else:
            x, y = value
            points[idx] = Landmark(x=x, y=y, visibility=visibility)
    return PoseFrame(
        landmarks=tuple(points),
        world_landmarks=world,
        frame_width=frame_width,
        frame_height=frame_height,
        timestamp_ms=timestamp_ms,
    )


def _raw_landmarks(n: int = N_LANDMARKS) -> list[dict[str, float]]:
    """JSON 载荷用的占位点列表（全在画面中心）。"""
    return [{"x": 0.5, "y": 0.5} for _ in range(n)]


def _raw_landmarks_with_nose(x: float, y: float) -> list[dict[str, float]]:
    points = _raw_landmarks()
    points[L.NOSE] = {"x": x, "y": y}
    return points


# ------------------------------------------------- 归一化 → 像素（核心）


class TestPixelRestoration:
    """`pixel()` 必须按宽、高分别折算 —— 本项目最易静默出错之处。

    若实现退化成「x、y 乘同一个数」，本类测试会立刻失败：坐标还原一错，
    所有角度特征全废，而且不会报错，只会静默给出错误数值。
    """

    def test_scales_x_by_width_and_y_by_height_on_non_square_frame(self) -> None:
        # 720×1280 竖屏：x 系数 720、y 系数 1280 必须各用各的。
        # 单系数退化实现会得到 (180, 540)、(320, 960) 之类的错误值。
        frame = make_frame(NOSE=(0.25, 0.75), frame_width=720, frame_height=1280)
        assert frame.pixel(L.NOSE) == pytest.approx((180.0, 960.0))

    def test_center_point_maps_to_half_of_each_dimension(self) -> None:
        frame = make_frame(frame_width=720, frame_height=1280)
        assert frame.pixel(L.NOSE) == pytest.approx((360.0, 640.0))

    def test_swapped_fractions_map_to_swapped_pixel_positions(self) -> None:
        frame = make_frame(
            NOSE=(0.75, 0.25),
            LEFT_FOOT_INDEX=(0.25, 0.75),
            frame_width=720,
            frame_height=1280,
        )
        assert frame.pixel(L.NOSE) == pytest.approx((540.0, 320.0))
        assert frame.pixel(L.LEFT_FOOT_INDEX) == pytest.approx((180.0, 960.0))

    def test_same_normalized_point_depends_on_frame_dimensions(self) -> None:
        portrait = make_frame(NOSE=(0.5, 0.5), frame_width=720, frame_height=1280)
        landscape = make_frame(NOSE=(0.5, 0.5), frame_width=1920, frame_height=1080)
        assert portrait.pixel(L.NOSE) == pytest.approx((360.0, 640.0))
        assert landscape.pixel(L.NOSE) == pytest.approx((960.0, 540.0))

    def test_out_of_range_normalized_coordinates_are_not_clamped(self) -> None:
        # 人出画时归一化坐标允许越界，还原时不得截断。
        frame = make_frame(NOSE=(-0.1, 1.2), frame_width=720, frame_height=1280)
        assert frame.pixel(L.NOSE) == pytest.approx((-72.0, 1536.0))

    def test_square_frame_scaling(self) -> None:
        frame = make_frame(NOSE=(0.12, 0.34), frame_width=1000, frame_height=1000)
        assert frame.pixel(L.NOSE) == pytest.approx((120.0, 340.0))


class TestPixelDerivedGeometry:
    """`pixel_mid` / `pixel_span` / `torso_length` 等派生量在像素空间计算。"""

    def test_pixel_mid_is_midpoint_in_pixel_space(self) -> None:
        frame = make_frame(LEFT_SHOULDER=(0.4, 0.2), RIGHT_SHOULDER=(0.6, 0.6))
        # 像素端点 (288,256) 与 (432,768) → 中点 (360,512)。
        assert frame.pixel_mid(L.LEFT_SHOULDER, L.RIGHT_SHOULDER) == pytest.approx((360.0, 512.0))

    def test_pixel_span_measures_pixel_distance(self) -> None:
        # 归一化差 (0.5,0.375) 在 720×1280 下是 (360,480) 像素 → 3-4-5 的 600。
        frame = make_frame(LEFT_WRIST=(0.25, 0.25), RIGHT_WRIST=(0.75, 0.625))
        assert frame.pixel_span(L.LEFT_WRIST, L.RIGHT_WRIST) == pytest.approx(600.0)

    def test_torso_length_is_shoulder_mid_to_hip_mid_in_pixels(self) -> None:
        frame = make_frame(
            LEFT_SHOULDER=(0.4, 0.2),
            RIGHT_SHOULDER=(0.6, 0.2),
            LEFT_HIP=(0.4, 0.5),
            RIGHT_HIP=(0.6, 0.5),
        )
        # 肩中点 (360,256)、髋中点 (360,640) → 384 像素。
        # 归一化空间算会得到 0.3、按宽折算会得到 216，均无法通过。
        assert frame.torso_length() == pytest.approx(384.0)

    def test_torso_length_handles_slanted_torso(self) -> None:
        frame = make_frame(
            LEFT_SHOULDER=(0.4, 0.2),
            RIGHT_SHOULDER=(0.6, 0.2),
            LEFT_HIP=(0.8, 0.5),
            RIGHT_HIP=(1.0, 0.5),
        )
        # 髋中点 (648,640) 相对肩中点 (360,256) 位移 (288,384) → 480。
        assert frame.torso_length() == pytest.approx(480.0)

    def test_shoulder_width_is_pixel_span_between_shoulders(self) -> None:
        frame = make_frame(LEFT_SHOULDER=(0.4, 0.2), RIGHT_SHOULDER=(0.6, 0.2))
        assert frame.shoulder_width() == pytest.approx(144.0)


# ------------------------------------------------------------------ 校验


class TestPoseFrameValidation:
    """构造期不变量：33 点、正数画幅。"""

    def test_pose_frame_error_is_value_error(self) -> None:
        assert issubclass(PoseFrameError, ValueError)

    @pytest.mark.parametrize("count", [0, 10, 32, 34])
    def test_landmarks_must_have_exactly_33_points(self, count: int) -> None:
        with pytest.raises(PoseFrameError, match="33"):
            PoseFrame(
                landmarks=tuple(Landmark(x=0.5, y=0.5) for _ in range(count)),
                frame_width=720,
                frame_height=1280,
                timestamp_ms=0,
            )

    @pytest.mark.parametrize("count", [0, 10, 32, 34])
    def test_world_landmarks_must_have_exactly_33_points(self, count: int) -> None:
        with pytest.raises(PoseFrameError, match="33"):
            PoseFrame(
                landmarks=tuple(Landmark(x=0.5, y=0.5) for _ in range(N_LANDMARKS)),
                world_landmarks=tuple(Landmark(x=0.0, y=0.0) for _ in range(count)),
                frame_width=720,
                frame_height=1280,
                timestamp_ms=0,
            )

    @pytest.mark.parametrize(
        ("frame_width", "frame_height"),
        [(0, 1280), (720, 0), (-720, 1280), (720, -1280)],
    )
    def test_frame_dimensions_must_be_positive(self, frame_width: int, frame_height: int) -> None:
        with pytest.raises(PoseFrameError, match="正"):
            PoseFrame(
                landmarks=tuple(Landmark(x=0.5, y=0.5) for _ in range(N_LANDMARKS)),
                frame_width=frame_width,
                frame_height=frame_height,
                timestamp_ms=0,
            )


def test_landmark_defaults_to_zero_depth_and_full_visibility() -> None:
    lm = Landmark(x=0.1, y=0.2)
    assert lm.z == pytest.approx(0.0)
    assert lm.visibility == pytest.approx(1.0)


# -------------------------------------------------------------- 世界坐标


class TestWorldLandmarks:
    """世界坐标缺失时必须是 None，不得用 0 冒充。"""

    def test_has_world_false_when_absent(self) -> None:
        frame = make_frame()
        assert frame.has_world is False

    def test_world_returns_none_not_zero_when_absent(self) -> None:
        # 铁律二：依赖世界坐标的特征在缺失时整体置 None，填 0 会造出假数据。
        frame = make_frame()
        assert frame.world(L.NOSE) is None
        assert frame.world(L.LEFT_HIP) is None

    def test_has_world_true_and_world_returns_meter_coordinates(self) -> None:
        frame = make_frame(world=make_world_landmarks(LEFT_HIP=(0.02, -0.15, -0.03)))
        assert frame.has_world is True
        assert frame.world(L.LEFT_HIP) == pytest.approx((0.02, -0.15, -0.03))

    def test_untouched_world_points_default_to_origin(self) -> None:
        frame = make_frame(world=make_world_landmarks(LEFT_HIP=(0.02, -0.15, -0.03)))
        assert frame.world(L.NOSE) == pytest.approx((0.0, 0.0, 0.0))


# ---------------------------------------------------------------- 可见性


class TestVisibility:
    """阈值判定是 `>=`：恰好等于阈值算可见。"""

    def test_is_visible_is_true_exactly_at_threshold(self) -> None:
        frame = make_frame(NOSE=Landmark(x=0.5, y=0.5, visibility=0.6))
        assert frame.is_visible(L.NOSE, 0.6) is True

    def test_is_visible_is_false_just_below_threshold(self) -> None:
        frame = make_frame(NOSE=Landmark(x=0.5, y=0.5, visibility=0.59))
        assert frame.is_visible(L.NOSE, 0.6) is False

    def test_visibility_accessor_returns_raw_value(self) -> None:
        frame = make_frame(LEFT_ANKLE=Landmark(x=0.5, y=0.5, visibility=0.42))
        assert frame.visibility(L.LEFT_ANKLE) == pytest.approx(0.42)

    def test_all_visible_true_when_every_point_meets_threshold(self) -> None:
        frame = make_frame(
            LEFT_KNEE=Landmark(x=0.5, y=0.5, visibility=0.5),
            RIGHT_KNEE=Landmark(x=0.5, y=0.5, visibility=0.75),
        )
        assert frame.all_visible((L.LEFT_KNEE, L.RIGHT_KNEE), 0.5) is True

    def test_all_visible_false_when_any_point_below_threshold(self) -> None:
        frame = make_frame(
            LEFT_KNEE=Landmark(x=0.5, y=0.5, visibility=0.5),
            RIGHT_KNEE=Landmark(x=0.5, y=0.5, visibility=0.49),
        )
        assert frame.all_visible((L.LEFT_KNEE, L.RIGHT_KNEE), 0.5) is False

    def test_mean_visibility_averages_all_points_by_default(self) -> None:
        frame = make_frame(NOSE=Landmark(x=0.5, y=0.5, visibility=0.0))
        assert frame.mean_visibility() == pytest.approx(32.0 / 33.0)

    def test_mean_visibility_averages_explicit_subset(self) -> None:
        frame = make_frame(
            LEFT_SHOULDER=Landmark(x=0.5, y=0.5, visibility=0.5),
            RIGHT_SHOULDER=Landmark(x=0.5, y=0.5, visibility=0.7),
        )
        assert frame.mean_visibility((L.LEFT_SHOULDER, L.RIGHT_SHOULDER)) == pytest.approx(0.6)


# ------------------------------------------------------------- 关节夹角


class TestJointAngle:
    """`joint_angle` 在函数内部完成像素还原，调用方无从写错坐标系。"""

    def test_restores_pixels_before_measuring_on_non_square_frame(self) -> None:
        # 720×1280 下：顶点 (0.5,0.5) → 像素 (360,640)；
        # 髋偏移 (-72,-96) 像素、踝偏移 (96,-72) 像素 → 像素空间恰为 90°。
        # 若直接用归一化坐标（忘了还原），夹角约 120.3°，本断言必然失败。
        frame = make_frame(
            LEFT_KNEE=(0.5, 0.5),
            LEFT_HIP=(0.4, 0.425),
            LEFT_ANKLE=(0.5 + 96.0 / 720.0, 0.5 - 72.0 / 1280.0),
        )
        assert joint_angle(frame, L.LEFT_HIP, L.LEFT_KNEE, L.LEFT_ANKLE) == pytest.approx(90.0)

    def test_straight_limb_gives_180_degrees(self) -> None:
        frame = make_frame(
            LEFT_KNEE=(0.5, 0.5),
            LEFT_HIP=(0.5, 0.25),
            LEFT_ANKLE=(0.5, 0.75),
        )
        assert joint_angle(frame, L.LEFT_HIP, L.LEFT_KNEE, L.LEFT_ANKLE) == pytest.approx(180.0)

    def test_folded_limb_with_coincident_endpoints_gives_0_degrees(self) -> None:
        frame = make_frame(
            LEFT_ELBOW=(0.5, 0.5),
            LEFT_SHOULDER=(0.3, 0.3),
            LEFT_WRIST=(0.3, 0.3),
        )
        assert joint_angle(frame, L.LEFT_SHOULDER, L.LEFT_ELBOW, L.LEFT_WRIST) == pytest.approx(
            0.0, abs=1e-9
        )

    def test_raises_when_endpoint_coincides_with_vertex(self) -> None:
        # 归一化坐标相同 → 像素坐标相同 → 向量零长，必须抛退化异常。
        frame = make_frame(LEFT_KNEE=(0.5, 0.5), LEFT_HIP=(0.5, 0.5))
        with pytest.raises(DegenerateGeometryError):
            joint_angle(frame, L.LEFT_HIP, L.LEFT_KNEE, L.LEFT_ANKLE)


# ------------------------------------------------------------- 尺寸换算


class TestScalingFactor:
    """米/像素换算，前提是本帧有世界坐标。"""

    def test_meters_per_pixel_from_nose_reference(self) -> None:
        frame = make_frame(
            NOSE=(0.5, 0.1),
            LEFT_SHOULDER=(0.5, 0.5),
            world=make_world_landmarks(LEFT_SHOULDER=(0.0, -0.4, 0.0)),
        )
        # 像素距离 |(360,128) - (360,640)| = 512；世界坐标距离 = 0.4 m。
        assert frame.scaling_factor(L.LEFT_SHOULDER) == pytest.approx(0.4 / 512.0)

    def test_raises_without_world_landmarks(self) -> None:
        frame = make_frame()
        with pytest.raises(PoseFrameError):
            frame.scaling_factor(L.LEFT_SHOULDER)

    def test_raises_when_reference_length_is_zero(self) -> None:
        # 以 NOSE 自身为参考点，像素距离为 0，缩放系数无定义。
        frame = make_frame(world=make_world_landmarks())
        with pytest.raises(PoseFrameError):
            frame.scaling_factor(L.NOSE)


# ------------------------------------------------------- JSON 载荷构造


class TestFramesFromJson:
    """离线回放 / golden fixture 入口。"""

    def test_builds_frames_and_keeps_timestamps(self) -> None:
        payload = [
            {"timestamp_ms": 33, "landmarks": _raw_landmarks(), "world_landmarks": None},
            {"timestamp_ms": 66, "landmarks": _raw_landmarks(), "world_landmarks": None},
        ]
        frames = frames_from_json(payload, frame_width=720, frame_height=1280)
        assert len(frames) == 2
        assert frames[0].timestamp_ms == 33
        assert frames[1].timestamp_ms == 66
        assert len(frames[0].landmarks) == N_LANDMARKS

    def test_null_world_landmarks_yields_none(self) -> None:
        payload = [{"timestamp_ms": 0, "landmarks": _raw_landmarks(), "world_landmarks": None}]
        frames = frames_from_json(payload, 720, 1280)
        assert frames[0].has_world is False
        assert frames[0].world(L.LEFT_HIP) is None

    def test_present_world_landmarks_are_parsed(self) -> None:
        world_points = [{"x": 0.0, "y": 0.0, "z": 0.0} for _ in range(N_LANDMARKS)]
        world_points[L.LEFT_HIP] = {"x": 0.01, "y": -0.2, "z": -0.05}
        payload = [
            {"timestamp_ms": 0, "landmarks": _raw_landmarks(), "world_landmarks": world_points}
        ]
        frames = frames_from_json(payload, 720, 1280)
        assert frames[0].has_world is True
        assert frames[0].world(L.LEFT_HIP) == pytest.approx((0.01, -0.2, -0.05))

    def test_optional_fields_get_defaults(self) -> None:
        # 缺省 z / visibility / timestamp_ms 时的默认值：0.0 / 1.0 / 0。
        payload = [{"landmarks": _raw_landmarks_with_nose(0.25, 0.75)}]
        frames = frames_from_json(payload, 720, 1280)
        nose = frames[0].landmarks[L.NOSE]
        assert (nose.x, nose.y, nose.z) == pytest.approx((0.25, 0.75, 0.0))
        assert nose.visibility == pytest.approx(1.0)
        assert frames[0].timestamp_ms == 0

    def test_pixel_restoration_uses_passed_dimensions(self) -> None:
        payload = [{"landmarks": _raw_landmarks_with_nose(0.25, 0.75), "world_landmarks": None}]
        frames = frames_from_json(payload, frame_width=720, frame_height=1280)
        assert frames[0].pixel(L.NOSE) == pytest.approx((180.0, 960.0))

    def test_empty_payload_returns_empty_list(self) -> None:
        assert frames_from_json([], 720, 1280) == []

    def test_wrong_landmark_count_raises_pose_frame_error(self) -> None:
        payload = [{"landmarks": _raw_landmarks(10), "world_landmarks": None}]
        with pytest.raises(PoseFrameError, match="33"):
            frames_from_json(payload, 720, 1280)
