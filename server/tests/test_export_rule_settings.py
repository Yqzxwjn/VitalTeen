"""工程参数导出物的自检。

这份 JSON 是手机端在**连不上决策服务时**复现判定的唯一依据，而它出错的方式很安静：
少一个键，端侧那份实现就退回一个写死的默认值，两侧从此不一致，谁也不会报错。
所以这里不校验「文件在不在」（那是 ``--check`` 的事），校验的是
**「它是不是真的够用」**。
"""

from __future__ import annotations

from dataclasses import fields

from app.service import DecisionSettings

from tools.export_rule_settings import (
    EXCLUDED_FIELDS,
    _EXPORTED_FIELDS,
    build,
    unknown_fields,
)


def test_whitelist_matches_the_dataclass() -> None:
    """白名单加排除表要**恰好**覆盖 ``DecisionSettings``。

    这条会在两种情况下红，两种都是有意义的：

    1. 字段被改名或删掉 —— 导出器会 ``AttributeError``，但那是运行时；
    2. **新增了一个设置项** —— 那一刻必须显式决定端侧要不要它。
       不管的话，新的工程参数只作用于服务端，手机断网时按旧规则算，
       产出一份与服务端不同、又看不出不同的报告。
    """
    declared = {field.name for field in fields(DecisionSettings)}
    covered = set(_EXPORTED_FIELDS) | set(EXCLUDED_FIELDS)

    assert not unknown_fields(), "白名单里有 DecisionSettings 已不存在的字段"
    assert declared == covered, (
        "DecisionSettings 与导出白名单/排除表不一致。\n"
        f"  只在类里、两侧都没提：{sorted(declared - covered)}\n"
        f"  只在表里、类里没有：{sorted(covered - declared)}\n"
        "新增字段时请明确它属于哪一边，并在 EXCLUDED_FIELDS 里写下理由。"
    )


def test_exported_keys_are_exactly_the_whitelist() -> None:
    payload = build()
    assert set(payload) == set(_EXPORTED_FIELDS) | {"_comment"}


def test_export_is_enough_to_reconstruct_the_settings() -> None:
    """导出物能原样反构造回默认的 ``DecisionSettings``。

    这是这份文件「够用」的定义：拿它对类的默认值重建，必须逐字段相等。
    哪天真有人把某个参数的默认值改了却忘了重新导出，``--check`` 会先红；
    这条则保证即使有人手工编辑了 JSON，也还是能查出它偏离了实现。
    """
    payload = {key: value for key, value in build().items() if key != "_comment"}
    rebuilt = DecisionSettings(
        **{
            key: tuple(value) if isinstance(value, list) else value
            for key, value in payload.items()
        }
    )
    assert rebuilt == DecisionSettings()


def test_rating_ladder_is_well_formed() -> None:
    """评级阶梯的两个方向都要成立 —— 拼错一个方向就会让「需改进」变成「优」。"""
    settings = DecisionSettings()
    assert len(settings.rating_labels) == len(settings.rating_cutoffs) + 1
    assert list(settings.rating_cutoffs) == sorted(settings.rating_cutoffs, reverse=True)


def test_bad_settings_are_rejected_at_construction() -> None:
    """配错的参数要在**构造时**炸，而不是安静地算出一份评级全错的报告。"""
    import pytest

    with pytest.raises(ValueError):
        DecisionSettings(severity_level_breakpoints=(0.67, 0.34))
    with pytest.raises(ValueError):
        DecisionSettings(rating_labels=("优", "良"))
    with pytest.raises(ValueError):
        DecisionSettings(rating_cutoffs=(60, 90, 80, 70))
    with pytest.raises(ValueError):
        DecisionSettings(score_worst_weight=0.0, score_mean_weight=0.0)
    # 0 是合法的：它表示「不建议任何方案」，有测试依赖这个语义。
    assert DecisionSettings(max_plans=0).max_plans == 0
    with pytest.raises(ValueError):
        DecisionSettings(max_plans=-1)
