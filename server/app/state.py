"""把结构化决策请求转成 Laya 能消费的 state。

**这是整个架构里最关键的一次转换。** Laya 看不到视频、看不到关键点、看不到任何
图像 —— 它对用户动作的全部认知，就是这里产出的那段文本。写得含糊，它就判不准；
写得太长，它会因为上下文窗口被截断（多语言权重是 1024 token）。

三条写作原则
------------

**一、只陈述测量，不预先下结论。**

state 里出现的是「最深膝角 92 度」「合格线 95 度」，而不是「深度不足」。
把结论和证据一起喂进去，等于替模型想好了答案又让它「确认一下」——
那样测出来的不是模型的判断力，而是它对输入的顺从程度。

**二、但候选集要如实给出。**

规则引擎已经产出的候选错误码必须原样列入。这不是「下结论」，而是划定了
判断的**边界**：决策层只能在这个封闭集里选，不得凭空发明一个错误类型
（见 ``docs/domain-layer-design.md`` §6.1 的职责边界）。

**三、上下文信息是判断依据，不是装饰。**

年龄、学段、机位、姿态后端都要写进去 —— 它们直接改变什么建议是合适的：
14 岁初中生和 18 岁高中生的训练剂量不同，侧拍机位下膝内扣根本不可判。
"""

from __future__ import annotations

from typing import Any

from .contracts import DecisionRequest

#: state 的字符预算。
#:
#: 多语言权重的上下文是 1024 token，中文大致 1–1.5 字/token，再扣掉问题模板本身
#: 占用的部分，留给 state 的安全余量约 800 字。超了不会报错 —— Laya 会**静默截断**，
#: 而截断会丢掉末尾的信息（实测中发现截断方向会显著改变答案），因此必须在
#: 构造侧就拦住。
MAX_STATE_CHARS = 800


class StateTooLongError(ValueError):
    """state 超出上下文预算。

    单独成类而不是复用 ValueError，是为了让调用方能针对性地降级
    （例如丢弃逐次动作明细、只保留组级统计），而不是笼统地失败。
    """


def _sex_zh(sex: str) -> str:
    return "男" if sex == "male" else "女"


def _view_zh(view: str) -> str:
    return {"frontal": "正视", "sagittal": "侧视", "oblique45": "斜前 45 度"}.get(view, view)


def _backend_zh(backend: str) -> str:
    return {"mlkit": "ML Kit", "mediapipe": "MediaPipe"}.get(backend, backend)


def _quality_line(request: DecisionRequest) -> str:
    q = request.pose_quality
    return (
        f"关键点可见性 {q.mean_visibility:.2f}，"
        f"有效帧占比 {q.coverage_ok_ratio:.2f}，"
        f"平均帧率 {q.fps_mean:.1f}，"
        f"最长丢帧 {q.gap_max_ms} 毫秒，"
        f"机位置信度 {q.view_confidence:.2f}"
    )


def _fault_lines(request: DecisionRequest) -> list[str]:
    """组级错误统计，每条一行。

    只写「出现了几次、偏离多少」，不写「这个问题严重」——
    严重度的判断是决策层的事（``score`` 原语），不是输入的一部分。
    """
    if not request.set.fault_stats:
        return ["（规则引擎未触发任何错误候选）"]

    total = request.set.rep_count or 1
    lines: list[str] = []
    for stat in request.set.fault_stats:
        share = stat.count / total
        reps = "、".join(str(i) for i in stat.reps) if stat.reps else "未记录"
        lines.append(
            f"- {stat.code}：命中 {stat.count} 次（占比 {share:.0%}），发生在第 {reps} 次"
        )
    return lines


def _rep_lines(request: DecisionRequest) -> list[str]:
    """逐次动作的关键指标。

    逐次明细是判断「问题是否稳定复现」的唯一依据 ——
    10 次里出现 1 次和出现 7 次是完全不同的结论，仅看组级汇总看不出来。
    """
    if not request.reps:
        return []
    lines: list[str] = []
    for rep in request.reps:
        parts = [f"第 {rep.index} 次"]
        if rep.faults:
            codes = "、".join(sorted({f.code for f in rep.faults}))
            parts.append(f"触发 {codes}")
        else:
            parts.append("未触发错误")
        for fault in rep.faults:
            for deviation in fault.deviations:
                parts.append(
                    f"{deviation.feature} 实测 {deviation.measured:.1f}"
                    f"／阈值 {deviation.threshold:.1f}"
                )
        # 置信度可能未提供（端侧只有组级汇总时）。不可用就不写，不填一个假数字 ——
        # 写成「置信度 0.00」会被读成「这次数据完全不可信」，与「不知道」是两回事。
        if rep.confidence is not None:
            parts.append(f"该次置信度 {rep.confidence:.2f}")
        lines.append("- " + "；".join(parts))
    return lines


def build_state(request: DecisionRequest) -> dict[str, Any]:
    """构造 Laya 的 ``state``。

    返回**扁平**字典：键是简短的中文短语，值是短文本或数值。
    嵌套结构在编码时会被引号与括号切碎，扁平化能让语义更完整地落到 token 上。

    Raises:
        StateTooLongError: 渲染后的 state 超出 :data:`MAX_STATE_CHARS`。
            调用方应降级（例如去掉逐次明细）后重试，而不是把超长的内容发出去 ——
            Laya 会静默截断，而截断方向会显著改变答案。
    """
    ctx = request.context

    state: dict[str, Any] = {
        "动作": f"{ctx.action_code}（{ctx.action_variant}）",
        "拍摄机位": _view_zh(ctx.camera_view),
        "姿态后端": _backend_zh(ctx.pose_backend),
        "米制世界坐标": "可用" if ctx.has_world_landmarks else "不可用（无高度与位移类特征）",
        "年龄": ctx.age,
        "性别": _sex_zh(ctx.sex),
        "学段": ctx.grade,
        "国标组别": ctx.standard_group,
        "完成次数": request.set.rep_count,
        "有效次数": request.set.valid_rep_count,
        "数据质量": _quality_line(request),
        "候选错误": "、".join(c.code for c in request.candidates) or "（无）",
        "错误统计": "\n".join(_fault_lines(request)),
    }

    if request.set.tempo_mean_ms is not None:
        state["平均单次用时"] = f"{request.set.tempo_mean_ms / 1000:.1f} 秒"
    if request.set.rom_mean_deg is not None:
        state["平均活动幅度"] = f"{request.set.rom_mean_deg:.1f} 度"
    if request.set.symmetry_index_mean is not None:
        state["平均左右对称指数"] = f"{request.set.symmetry_index_mean:.3f}"

    rep_lines = _rep_lines(request)
    if rep_lines:
        state["逐次明细"] = "\n".join(rep_lines)

    if len(render_state_text(state)) > MAX_STATE_CHARS:
        raise StateTooLongError(
            f"state 渲染后 {len(render_state_text(state))} 字，超过预算 {MAX_STATE_CHARS} 字。"
            "Laya 的上下文是 1024 token，超出会静默截断且截断方向会改变答案 —— "
            "请在调用前降级（例如去掉逐次明细）。"
        )
    return state


def build_state_lenient(request: DecisionRequest) -> tuple[dict[str, Any], bool]:
    """构造 state，超长时自动降级。

    返回 ``(state, 是否降级)``。

    降级顺序体现信息价值排序：先丢逐次明细（组级统计已能反映主要问题），
    仍超长再丢单次指标。**两条都丢完还超长就让它抛** —— 那种情况说明输入本身
    有问题（例如候选集异常庞大），掩盖它只会让错误延后到更难定位的地方。
    """
    try:
        return build_state(request), False
    except StateTooLongError:
        pass

    trimmed = request.model_copy(update={"reps": []})
    try:
        state = build_state(trimmed)
        state["说明"] = "逐次明细因长度限制已省略"
        return state, True
    except StateTooLongError:
        minimal = trimmed.model_copy(
            update={
                "set": trimmed.set.model_copy(
                    update={
                        "tempo_mean_ms": None,
                        "rom_mean_deg": None,
                        "symmetry_index_mean": None,
                    }
                )
            }
        )
        state = build_state(minimal)
        state["说明"] = "逐次明细与部分组级指标因长度限制已省略"
        return state, True


def render_state_text(state: dict[str, Any]) -> str:
    """把 state 渲染成人类可读文本。

    两个用途：估算长度，以及**让人能看懂喂给模型的到底是什么**。
    决策出问题时，第一个要看的就是这段文本 —— 如果它没法读，调试就无从下手。
    """
    lines: list[str] = []
    for key, value in state.items():
        text = str(value)
        if "\n" in text:
            lines.append(f"{key}：")
            lines.extend(f"  {part}" for part in text.splitlines())
        else:
            lines.append(f"{key}：{text}")
    return "\n".join(lines)


__all__ = [
    "MAX_STATE_CHARS",
    "StateTooLongError",
    "build_state",
    "build_state_lenient",
    "render_state_text",
]
