"""``vitalteen_domain.geometry`` 几何算子测试。

锁死的约定（docs/domain-layer-design.md §1.2、§2.1）：

- 所有算子输入的都是【像素坐标】；图像坐标系 y 轴向下。
- ``tilt_from_vertical``：线段竖直向上为 0°，向图像右侧倾斜为正。
- ``tilt_from_horizontal``：水平向右为 0°，向上倾斜为正。
- ``signed_offset``：图像坐标系下正值表示 p 位于定向直线 a→b 的顺时针一侧。
- 一切退化输入（零长向量、零长参考线段、非正时间差）抛
  ``DegenerateGeometryError``，而不是静默返回 0 或 NaN。

已知实现偏差（已在对应测试上标记 xfail，待实现方修复）：
``tilt_from_horizontal`` 对纯左向向量返回 -180.0，违反其 docstring 声明的
取值范围 (-180, 180]（详见 ``TestTiltFromHorizontal``）。
"""

from __future__ import annotations

import math

import pytest

from vitalteen_domain.geometry import (
    DegenerateGeometryError,
    angle3,
    angular_velocity_deg_s,
    dist_ratio,
    distance,
    midpoint,
    signed_offset,
    symmetry_index,
    tilt_from_horizontal,
    tilt_from_vertical,
)

#: 期望值精确为 0 时的绝对容差（浮点比较不用 ==）。
ZERO_TOL = 1e-9


class TestAngle3:
    """顶点是第二个参数 b；返回角度制，取值 [0, 180]。"""

    def test_vertex_is_second_argument(self) -> None:
        # 文档给定示例：角在 b=(0,100) 处，向量 BA=(0,-100) 与 BC=(100,0) 垂直。
        assert angle3((0.0, 0.0), (0.0, 100.0), (100.0, 100.0)) == pytest.approx(90.0)

    def test_45_degrees(self) -> None:
        assert angle3((100.0, 0.0), (0.0, 0.0), (100.0, 100.0)) == pytest.approx(45.0)

    def test_60_degrees(self) -> None:
        assert angle3((1.0, 0.0), (0.0, 0.0), (0.5, math.sqrt(3) / 2.0)) == pytest.approx(60.0)

    def test_180_degrees_when_rays_are_opposite(self) -> None:
        assert angle3((100.0, 5.0), (0.0, 5.0), (-100.0, 5.0)) == pytest.approx(180.0)

    def test_0_degrees_when_both_points_on_same_ray(self) -> None:
        assert angle3((100.0, 0.0), (0.0, 0.0), (37.0, 0.0)) == pytest.approx(0.0, abs=ZERO_TOL)

    def test_swapping_a_and_c_does_not_change_angle(self) -> None:
        first = angle3((10.0, 0.0), (0.0, 0.0), (3.0, 4.0))
        second = angle3((3.0, 4.0), (0.0, 0.0), (10.0, 0.0))
        assert first == pytest.approx(second)

    def test_raises_when_a_coincides_with_vertex(self) -> None:
        with pytest.raises(DegenerateGeometryError):
            angle3((5.0, 5.0), (5.0, 5.0), (10.0, 5.0))

    def test_raises_when_c_coincides_with_vertex(self) -> None:
        with pytest.raises(DegenerateGeometryError):
            angle3((10.0, 5.0), (5.0, 5.0), (5.0, 5.0))

    def test_raises_when_vector_is_below_epsilon(self) -> None:
        # 1e-12 的偏移在内部容差内视同零长，不得静默返回某个角度。
        with pytest.raises(DegenerateGeometryError):
            angle3((1e-12, 0.0), (0.0, 0.0), (10.0, 0.0))


class TestTiltFromVertical:
    """图像坐标 y 向下：线段竖直向上（b 在 a 上方）为 0°，向图像右侧倾斜为正。"""

    def test_0_when_b_is_directly_above_a(self) -> None:
        assert tilt_from_vertical((100.0, 300.0), (100.0, 100.0)) == pytest.approx(
            0.0, abs=ZERO_TOL
        )

    def test_90_when_pointing_to_image_right(self) -> None:
        assert tilt_from_vertical((0.0, 0.0), (100.0, 0.0)) == pytest.approx(90.0)

    def test_negative_90_when_pointing_to_image_left(self) -> None:
        assert tilt_from_vertical((0.0, 0.0), (-100.0, 0.0)) == pytest.approx(-90.0)

    def test_135_when_pointing_down_right(self) -> None:
        # 向右下（y 增大）倾斜仍属「右侧」，符号为正：atan2(100, -100) = 135。
        assert tilt_from_vertical((0.0, 0.0), (100.0, 100.0)) == pytest.approx(135.0)

    def test_180_when_b_directly_below_a(self) -> None:
        assert tilt_from_vertical((0.0, 0.0), (0.0, 100.0)) == pytest.approx(180.0)

    def test_raises_on_zero_length_segment(self) -> None:
        with pytest.raises(DegenerateGeometryError):
            tilt_from_vertical((7.0, 7.0), (7.0, 7.0))


class TestTiltFromHorizontal:
    """水平向右为 0°，向上倾斜为正。"""

    def test_0_when_horizontal_to_the_right(self) -> None:
        assert tilt_from_horizontal((0.0, 50.0), (100.0, 50.0)) == pytest.approx(
            0.0, abs=ZERO_TOL
        )

    def test_45_when_tilted_up_right(self) -> None:
        assert tilt_from_horizontal((0.0, 100.0), (100.0, 0.0)) == pytest.approx(45.0)

    def test_90_when_straight_up(self) -> None:
        assert tilt_from_horizontal((0.0, 100.0), (0.0, 0.0)) == pytest.approx(90.0)

    def test_negative_90_when_straight_down(self) -> None:
        assert tilt_from_horizontal((0.0, 0.0), (0.0, 100.0)) == pytest.approx(-90.0)

    def test_135_when_tilted_up_left(self) -> None:
        assert tilt_from_horizontal((100.0, 0.0), (0.0, -100.0)) == pytest.approx(135.0)

    def test_negative_135_when_tilted_down_left(self) -> None:
        assert tilt_from_horizontal((100.0, 0.0), (0.0, 100.0)) == pytest.approx(-135.0)

    def test_180_when_pointing_left(self) -> None:
        # 回归测试（负零陷阱）：v = (-100.0, 0.0) 时 -v[1] 得到 -0.0，
        # 而 atan2(-0.0, -100.0) 返回 -π 而非 +π，曾使本函数返回 -180.0、
        # 落在 docstring 声明的 (-180, 180] 之外。_normalize_signed_degrees 负责折回。
        assert tilt_from_horizontal((100.0, 0.0), (0.0, 0.0)) == pytest.approx(180.0)

    def test_no_negative_zero_leaks(self) -> None:
        # 水平右向曾返回 -0.0。数值上等于 0，但 JSON 序列化后会写成 -0.0，
        # 破坏与 Dart 端侧实现的精确比对（见设计文档 §8 跨语言一致性）。
        result = tilt_from_horizontal((0.0, 0.0), (100.0, 0.0))
        assert result == pytest.approx(0.0)
        assert not str(result).startswith("-"), f"输出泄漏了负零：{result!r}"

    def test_raises_on_zero_length_segment(self) -> None:
        with pytest.raises(DegenerateGeometryError):
            tilt_from_horizontal((7.0, 7.0), (7.0, 7.0))


class TestSignedOffset:
    """图像坐标 y 向下：正值 = p 位于 a→b 的顺时针一侧。"""

    def test_positive_below_a_rightward_line(self) -> None:
        # a→b 指向图像右侧（3 点钟方向），顺时针一侧是图像下方（6 点钟）。
        assert signed_offset((50.0, 100.0), (0.0, 0.0), (100.0, 0.0)) == pytest.approx(100.0)

    def test_negative_above_a_rightward_line(self) -> None:
        assert signed_offset((50.0, -100.0), (0.0, 0.0), (100.0, 0.0)) == pytest.approx(-100.0)

    def test_positive_left_of_a_downward_line(self) -> None:
        # a→b 指向图像下方（6 点钟方向），顺时针一侧是图像左侧（9 点钟）。
        assert signed_offset((-50.0, 50.0), (0.0, 0.0), (0.0, 100.0)) == pytest.approx(50.0)

    def test_zero_when_point_on_the_line(self) -> None:
        assert signed_offset((37.0, 0.0), (0.0, 0.0), (100.0, 0.0)) == pytest.approx(
            0.0, abs=ZERO_TOL
        )

    def test_magnitude_equals_perpendicular_distance(self) -> None:
        # 不是投影距离：p 在 a 正上方，垂距应为 1 像素。
        assert signed_offset((5.0, 1.0), (0.0, 0.0), (10.0, 0.0)) == pytest.approx(1.0)

    def test_sign_flips_when_a_and_b_swap(self) -> None:
        p = (50.0, 100.0)
        forward = signed_offset(p, (0.0, 0.0), (100.0, 0.0))
        backward = signed_offset(p, (100.0, 0.0), (0.0, 0.0))
        assert forward == pytest.approx(-backward)

    def test_raises_when_baseline_is_zero_length(self) -> None:
        with pytest.raises(DegenerateGeometryError):
            signed_offset((1.0, 1.0), (3.0, 3.0), (3.0, 3.0))


class TestSymmetryIndex:
    """``2|L-R|/(L+R)``：完全对称时为 0。"""

    def test_zero_when_perfectly_symmetric(self) -> None:
        assert symmetry_index(90.0, 90.0) == pytest.approx(0.0, abs=ZERO_TOL)

    def test_known_value_two_thirds(self) -> None:
        # 2·|90-45|/(90+45) = 90/135 = 2/3。
        assert symmetry_index(90.0, 45.0) == pytest.approx(2.0 / 3.0)

    def test_order_of_arguments_does_not_matter(self) -> None:
        assert symmetry_index(45.0, 90.0) == pytest.approx(symmetry_index(90.0, 45.0))

    def test_max_2_when_one_side_is_zero(self) -> None:
        assert symmetry_index(0.0, 10.0) == pytest.approx(2.0)
        assert symmetry_index(10.0, 0.0) == pytest.approx(2.0)

    def test_raises_when_left_and_right_cancel_out(self) -> None:
        # L = -R 时左右之和为 0，公式无定义（反对称是退化输入）。
        with pytest.raises(DegenerateGeometryError):
            symmetry_index(5.0, -5.0)

    def test_raises_when_sum_is_zero(self) -> None:
        with pytest.raises(DegenerateGeometryError):
            symmetry_index(0.0, 0.0)

    def test_raises_when_sum_is_below_epsilon(self) -> None:
        with pytest.raises(DegenerateGeometryError):
            symmetry_index(1e-12, 0.0)


class TestDistRatio:
    """两点距离 / 参考线段长度，参考长度取自人体尺度（如躯干长）。"""

    def test_known_value(self) -> None:
        # (0,0)-(30,40) 距离 50；参考线段长 100。
        assert dist_ratio((0.0, 0.0), (30.0, 40.0), (0.0, 0.0), (100.0, 0.0)) == pytest.approx(0.5)

    def test_ratio_halves_when_reference_doubles(self) -> None:
        p, q = (0.0, 0.0), (30.0, 40.0)
        short = dist_ratio(p, q, (0.0, 0.0), (50.0, 0.0))
        long = dist_ratio(p, q, (0.0, 0.0), (100.0, 0.0))
        assert long == pytest.approx(short / 2.0)

    def test_zero_when_points_coincide(self) -> None:
        assert dist_ratio((3.0, 3.0), (3.0, 3.0), (0.0, 0.0), (100.0, 0.0)) == pytest.approx(
            0.0, abs=ZERO_TOL
        )

    def test_raises_when_reference_is_zero_length(self) -> None:
        with pytest.raises(DegenerateGeometryError):
            dist_ratio((0.0, 0.0), (1.0, 0.0), (5.0, 5.0), (5.0, 5.0))

    def test_raises_when_reference_is_below_epsilon(self) -> None:
        with pytest.raises(DegenerateGeometryError):
            dist_ratio((0.0, 0.0), (1.0, 0.0), (5.0, 5.0), (5.0 + 1e-12, 5.0))


class TestMidpointAndDistance:
    """无退化分支的两个基础算子。"""

    def test_midpoint_averages_coordinates(self) -> None:
        assert midpoint((0.0, 0.0), (10.0, 20.0)) == pytest.approx((5.0, 10.0))

    def test_midpoint_with_negative_coordinates(self) -> None:
        assert midpoint((-4.0, 6.0), (2.0, -2.0)) == pytest.approx((-1.0, 2.0))

    def test_distance_is_euclidean(self) -> None:
        assert distance((0.0, 0.0), (3.0, 4.0)) == pytest.approx(5.0)

    def test_distance_is_zero_for_identical_points(self) -> None:
        assert distance((2.0, -3.0), (2.0, -3.0)) == pytest.approx(0.0, abs=ZERO_TOL)


class TestAngularVelocity:
    """角度变化率，单位 度/秒。"""

    def test_negative_rate_when_angle_decreases(self) -> None:
        # (30 - 90) / 1.0s = -60 deg/s。
        assert angular_velocity_deg_s(90.0, 30.0, 1000.0) == pytest.approx(-60.0)

    def test_positive_rate_over_half_second(self) -> None:
        # (90 - 30) / 0.5s = 120 deg/s。
        assert angular_velocity_deg_s(30.0, 90.0, 500.0) == pytest.approx(120.0)

    def test_zero_when_angle_unchanged(self) -> None:
        assert angular_velocity_deg_s(45.0, 45.0, 33.0) == pytest.approx(0.0, abs=ZERO_TOL)

    def test_raises_on_zero_dt(self) -> None:
        # 时间戳重复（dt = 0）没有变化率定义。
        with pytest.raises(DegenerateGeometryError):
            angular_velocity_deg_s(0.0, 10.0, 0.0)

    def test_raises_on_negative_dt(self) -> None:
        # 时间戳乱序同样拒绝，而不是返回反号的速度。
        with pytest.raises(DegenerateGeometryError):
            angular_velocity_deg_s(0.0, 10.0, -33.0)


def test_degenerate_geometry_error_is_value_error() -> None:
    """调用方（特征层）依赖 ValueError 族做统一捕获。"""
    assert issubclass(DegenerateGeometryError, ValueError)
