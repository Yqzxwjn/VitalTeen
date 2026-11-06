"""矫正方案库。

决策层的 ``choice.selected_plan_ids`` 从这里取候选。

**内容与剂量是两回事，本模块把它们分开对待。**

- **动作与机制**来自运动科学文献，有据可查（每条方案带 ``evidence_refs``）。
  例如「动态膝外翻与髋外展/外旋肌力不足相关，故以髋周激活与强化为主」——
  这是同行评审的结论，不是我们的发明。
- **组次剂量**（几组、几次、每周几次、持续几周）属于设计文档 §7.3 第 12 条
  明确列为**待体育专业成员核定**的内容。本项目不编造这类数字：一个看似专业的
  「3 组 × 12 次」如果来源不明，青少年照着练出了问题，责任是无法推脱的。

因此每条方案都有 :attr:`CorrectionPlan.status`：

- ``draft`` —— 结构与机制已就位，剂量待核定。**不出现在用户端。**
- ``active`` —— 已由体育专业成员核定，可用于决策。

这与阈值治理是同一套思路（见 ``shared/thresholds/`` 的 ``source_type``）：
**未核定的内容可以驱动「研究」，但不能驱动「建议」。**
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from enum import StrEnum


class PlanCategory(StrEnum):
    """训练手段的大类。决定方案在计划表里的排序与搭配。"""

    STRETCH = "stretch"
    """放松/柔韧：改善活动度受限。"""

    ACTIVATION = "activation"
    """激活：唤醒参与不足的肌群，常放在训练前。"""

    STRENGTHENING = "strengthening"
    """强化：提升肌力与耐力。"""

    MOTOR_RETRAINING = "motor_retraining"
    """动作模式再训练：重建正确的动作控制，而非单纯加力量。"""


class PlanStatus(StrEnum):
    """方案内容的核定状态。"""

    DRAFT = "draft"
    """机制已核对，剂量待体育专业成员核定。不得出现在用户端。"""

    ACTIVE = "active"
    """已核定，可用于决策。"""

    DEPRECATED = "deprecated"
    """已废弃，保留记录以免历史决策无法复现。"""


@dataclass(frozen=True, slots=True)
class Dosage:
    """训练剂量。

    ``None`` 表示**该项尚未核定**，而不是「不需要」。渲染时应当显示
    「剂量待教师核定」，绝不能因为字段为空就省略整句 —— 那会让用户以为
    这个动作没有剂量要求。
    """

    sets: int | None = None
    reps: int | None = None
    hold_seconds: int | None = None
    freq_per_week: int | None = None
    duration_weeks: int | None = None

    @property
    def is_ratified(self) -> bool:
        return None not in (self.sets, self.freq_per_week)

    def describe(self) -> str:
        """人类可读的剂量描述。未核定时如实说明。"""
        if not self.is_ratified:
            return "剂量待体育专业成员核定"
        parts: list[str] = []
        if self.reps is not None:
            parts.append(f"{self.sets} 组 × {self.reps} 次")
        elif self.hold_seconds is not None:
            parts.append(f"{self.sets} 组 × 每组 {self.hold_seconds} 秒")
        else:
            parts.append(f"{self.sets} 组")
        parts.append(f"每周 {self.freq_per_week} 次")
        if self.duration_weeks is not None:
            parts.append(f"持续 {self.duration_weeks} 周")
        return "，".join(parts)


@dataclass(frozen=True, slots=True)
class CorrectionPlan:
    """一条矫正方案。

    Args:
        plan_id: 稳定编码，会出现在决策响应与历史记录里，**不可随意更改**。
        target_fault_codes: 该方案针对的错误码（多对多）。
        instructions: 动作要领分步。写成给青少年看的语言，不是教练手册。
        key_cues: 一句话提示语，供 App 语音或字幕使用。
        contraindications: 禁忌与警示。**任何一条都不允许为空串**——
            这是青少年使用场景，宁可写得保守。
        equipment: 该方案**真正需要额外准备**的器材。

            墙、地面、椅子这类随处可见的东西**不算器材**。把它们列进来会让
            「家里没器材」的学生被排除在所有地面动作之外 —— 而他们完全能做，
            只是需要一块空地。这个语义一旦放宽，会直接影响推荐结果：
            默认 ``available_equipment=()``（假定徒手）时，方案库里将一条都选不出来。

            目前只有**弹力带**属于需要专门购买的一项。
        evidence_refs: 机制依据的来源。空元组表示该方案尚无文献支撑，
            这种方案不应进入 ``active``。
    """

    plan_id: str
    name_zh: str
    category: PlanCategory
    target_fault_codes: tuple[str, ...]
    goal: str
    instructions: tuple[str, ...]
    key_cues: tuple[str, ...]
    dosage: Dosage
    equipment: tuple[str, ...]
    difficulty: int
    age_min: int
    age_max: int
    grade_fit: tuple[str, ...]
    contraindications: tuple[str, ...]
    evidence_refs: tuple[str, ...] = ()
    status: PlanStatus = PlanStatus.DRAFT
    reviewed_by: str | None = None
    reviewed_at: str | None = None

    def __post_init__(self) -> None:
        if not 1 <= self.difficulty <= 5:
            raise ValueError(f"{self.plan_id}: difficulty 必须在 1–5，实际 {self.difficulty}")
        if self.age_min > self.age_max:
            raise ValueError(f"{self.plan_id}: age_min({self.age_min}) > age_max({self.age_max})")
        if not self.target_fault_codes:
            raise ValueError(f"{self.plan_id}: 必须声明至少一个目标错误码")
        if self.status is PlanStatus.ACTIVE and not self.evidence_refs:
            raise ValueError(
                f"{self.plan_id}: 状态为 active 但没有证据来源。"
                "没有文献支撑的方案不能作为建议推送给用户。"
            )

    def covers(self, fault_code: str) -> bool:
        return fault_code in self.target_fault_codes

    def suitable_for_age(self, age: int) -> bool:
        return self.age_min <= age <= self.age_max

    def requires_equipment(self, available: Iterable[str]) -> bool:
        """在给定器材条件下是否可用。无器材要求的方案恒为可用。"""
        held = set(available)
        return all(item in held for item in self.equipment)


#: 常用证据来源的简写，避免每条方案重复一长串 URL。
EVIDENCE = {
    "jospt_pfp": "JOSPT 髌股痛临床实践指南（2019）",
    "nsca_youth": "NSCA 青少年抗阻训练立场声明",
    "wblt": "负重弓步测试（WBLT）踝背屈国际正常值研究",
    "squat_depth": "深蹲深度生物力学文献（膝屈曲角与躯干角）",
}


#: 全部年龄段的通用范围。具体方案的适用年龄在 13–18 岁青少年体测场景下统一，
#: 差异体现在学段与难度上。
_YOUTH = (12, 18)


def _plans() -> tuple[CorrectionPlan, ...]:
    """种子方案库。

    **全部为 DRAFT**：动作与机制有据可查，剂量待体育专业成员核定。
    这不是偷懒 —— 未经核定的训练处方不该出现在青少年用户面前。
    """
    return (
        CorrectionPlan(
            plan_id="COR_GLUTE_BRIDGE",
            name_zh="臀桥",
            category=PlanCategory.ACTIVATION,
            target_fault_codes=("KNEE_VALGUS", "PELVIC_COMPENSATION"),
            goal="激活臀大肌，改善下蹲时髋主导不足、膝代偿内扣的倾向",
            instructions=(
                "仰卧屈膝，双脚踩地与髋同宽，脚跟距臀部约一掌长",
                "呼气时脚跟发力把髋抬起，直到肩-髋-膝接近一条直线",
                "在顶点停一拍，感受臀部发力而不是腰部",
                "控制速度落下，不要让髋砸向地面",
            ),
            key_cues=("用脚跟推地", "臀部发力，不要塌腰"),
            dosage=Dosage(),
            equipment=(),
            difficulty=1,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("小学高年级", "初中", "高中"),
            contraindications=("腰部在动作中出现疼痛时立即停止",),
            evidence_refs=(EVIDENCE["jospt_pfp"],),
        ),
        CorrectionPlan(
            plan_id="COR_CLAMSHELL",
            name_zh="蚌式开合",
            category=PlanCategory.ACTIVATION,
            target_fault_codes=("KNEE_VALGUS",),
            goal="强化髋外旋与外展肌群，减少动态膝外翻",
            instructions=(
                "侧卧，双膝屈约 90 度，双脚并拢",
                "保持骨盆不向后滚动，上侧膝盖向上打开",
                "打开到最大幅度停一拍，再缓慢合拢",
                "全程只有髋在动，腰部不要代偿旋转",
            ),
            key_cues=("骨盆别往后倒", "用臀部外侧发力"),
            dosage=Dosage(),
            equipment=(),
            difficulty=1,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("小学高年级", "初中", "高中"),
            contraindications=("髋部弹响伴随疼痛时停止并咨询医生",),
            evidence_refs=(EVIDENCE["jospt_pfp"],),
        ),
        CorrectionPlan(
            plan_id="COR_LATERAL_BAND_WALK",
            name_zh="弹力带侧向行走",
            category=PlanCategory.STRENGTHENING,
            target_fault_codes=("KNEE_VALGUS", "ASYMMETRY"),
            goal="在负重移动中维持膝-踝对齐，把髋外展力量转化为动态控制",
            instructions=(
                "弹力带套在膝上方或踝部，半蹲预备",
                "保持膝盖对准脚尖方向，向一侧横向迈步",
                "每一步都要控制，不要让前脚把后脚「拽」过去",
                "往返为一组，两侧都要做",
            ),
            key_cues=("膝盖对准脚尖", "慢一点，别让带子把你拉回去"),
            dosage=Dosage(),
            equipment=("弹力带",),
            difficulty=2,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("初中", "高中"),
            contraindications=("膝关节不稳或既往韧带损伤者需教师评估后使用",),
            evidence_refs=(EVIDENCE["jospt_pfp"],),
        ),
        CorrectionPlan(
            plan_id="COR_WALL_SIT",
            name_zh="靠墙静蹲",
            category=PlanCategory.STRENGTHENING,
            target_fault_codes=("INSUFFICIENT_DEPTH", "TEMPO_UNCONTROLLED"),
            goal="在无痛范围内建立屈膝位下的等长耐力与控制",
            instructions=(
                "背部贴墙，双脚前移约一步，与肩同宽",
                "沿墙下滑至膝关节约 90 度，以不痛为限",
                "膝盖对准脚尖方向，不要内扣",
                "保持均匀呼吸，不要憋气",
            ),
            key_cues=("膝盖别超过脚尖太多", "以不痛为准，不必强求九十度"),
            dosage=Dosage(),
            equipment=(),
            difficulty=1,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("小学高年级", "初中", "高中"),
            contraindications=("膝前痛在静蹲中加重时立即减小角度或停止",),
            evidence_refs=(EVIDENCE["jospt_pfp"],),
        ),
        CorrectionPlan(
            plan_id="COR_BOX_SQUAT",
            name_zh="箱式蹲（椅式蹲）",
            category=PlanCategory.MOTOR_RETRAINING,
            target_fault_codes=("INSUFFICIENT_DEPTH", "TEMPO_UNCONTROLLED", "EXCESSIVE_TRUNK_LEAN"),
            goal="用触凳给深度一个明确的目标，重建下蹲的动作模式与离心控制",
            instructions=(
                "站在椅子或矮凳前，双脚与肩同宽",
                "臀部向后向下坐，用 3 秒慢速下蹲",
                "臀部轻触凳面后停一拍，不要完全坐实",
                "脚跟发力站起，全程膝盖对准脚尖",
            ),
            key_cues=("慢下去，别坐实", "屁股往后坐，不是往下跪"),
            dosage=Dosage(),
            equipment=(),
            difficulty=1,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("小学高年级", "初中", "高中"),
            contraindications=("下蹲过程中出现膝关节疼痛时减小幅度",),
            evidence_refs=(EVIDENCE["squat_depth"],),
        ),
        CorrectionPlan(
            plan_id="COR_KNEE_TO_WALL",
            name_zh="膝触墙踝背屈",
            category=PlanCategory.STRETCH,
            target_fault_codes=("HEEL_RISE", "INSUFFICIENT_DEPTH"),
            goal="改善踝背屈活动度——它是深蹲时脚跟离地与深度受限的常见根本原因",
            instructions=(
                "面对墙站立，被测脚在前，脚尖距墙约一拳",
                "保持脚跟不离地，膝盖向前推向墙面",
                "触到墙后停一拍再退回，逐步加大脚尖与墙的距离",
                "全程脚跟必须贴地，一旦抬起就说明超过了当前活动度",
            ),
            key_cues=("脚跟不许离地", "膝盖对准第二脚趾推过去"),
            dosage=Dosage(),
            equipment=(),
            difficulty=1,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("小学高年级", "初中", "高中"),
            contraindications=("踝关节急性损伤期不做",),
            evidence_refs=(EVIDENCE["wblt"],),
        ),
        CorrectionPlan(
            plan_id="COR_CALF_STRETCH",
            name_zh="小腿三头肌拉伸",
            category=PlanCategory.STRETCH,
            target_fault_codes=("HEEL_RISE",),
            goal="放松小腿后侧，配合踝背屈活动度改善",
            instructions=(
                "面墙站立，双手扶墙，前后分腿",
                "后腿伸直、脚跟贴地，身体缓慢前倾",
                "再以屈膝版本拉伸比目鱼肌，同样保持脚跟贴地",
                "每个姿势保持均匀呼吸，不弹振",
            ),
            key_cues=("后脚跟踩住", "不要来回弹，稳住呼吸"),
            dosage=Dosage(),
            equipment=(),
            difficulty=1,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("小学高年级", "初中", "高中"),
            contraindications=("拉伸中出现小腿撕裂样疼痛立即停止",),
            evidence_refs=(EVIDENCE["wblt"],),
        ),
        CorrectionPlan(
            plan_id="COR_DEAD_BUG",
            name_zh="死虫式",
            category=PlanCategory.ACTIVATION,
            target_fault_codes=("PU_HIP_SAG", "PELVIC_COMPENSATION"),
            goal="在四肢移动时维持腰椎稳定，改善塌腰与骨盆控制",
            instructions=(
                "仰卧屈髋屈膝 90 度，双臂指向上方",
                "腰部轻压地面，全程保持这个压力",
                "对侧手臂与腿缓慢伸出，仍能保持腰部贴地",
                "回到起始位置，换另一侧",
            ),
            key_cues=("腰别离开地面", "伸出去的速度越慢越有效"),
            dosage=Dosage(),
            equipment=(),
            difficulty=2,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("初中", "高中"),
            contraindications=("腰部在动作中离地拱起时减小幅度",),
            evidence_refs=(EVIDENCE["nsca_youth"],),
        ),
        CorrectionPlan(
            plan_id="COR_BIRD_DOG",
            name_zh="鸟狗式",
            category=PlanCategory.ACTIVATION,
            target_fault_codes=("ASYMMETRY", "PU_HIP_SAG"),
            goal="训练对侧协调与骨盆抗旋转控制",
            instructions=(
                "四点跪位，手在肩下、膝在髋下",
                "对侧手脚同时向前后伸出，保持骨盆不旋转",
                "在末端停一拍，感受躯干稳定而不是四肢发力",
                "缓慢收回，换另一侧",
            ),
            key_cues=("骨盆不要歪", "想象背上放着一杯水"),
            dosage=Dosage(),
            equipment=(),
            difficulty=2,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("初中", "高中"),
            contraindications=("腕关节不适时改用前臂支撑",),
            evidence_refs=(EVIDENCE["nsca_youth"],),
        ),
        CorrectionPlan(
            plan_id="COR_FRONT_PLANK",
            name_zh="前平板支撑",
            category=PlanCategory.STRENGTHENING,
            target_fault_codes=("PU_HIP_SAG", "KNEE_VALGUS"),
            goal="建立躯干整体刚性，为俯卧撑与深蹲提供稳定基础",
            instructions=(
                "肘部位于肩关节正下方，前臂贴地",
                "头-肩-髋-踝尽量成一条直线",
                "腹部与臀部同时收紧，不要塌腰也不要拱背",
                "保持均匀呼吸，坚持到姿势开始变形就结束",
            ),
            key_cues=("屁股别翘也别塌", "宁可时间短，不要姿势散"),
            dosage=Dosage(),
            equipment=(),
            difficulty=2,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("小学高年级", "初中", "高中"),
            contraindications=("腰部在支撑中出现疼痛时立即结束",),
            evidence_refs=(EVIDENCE["nsca_youth"],),
        ),
        CorrectionPlan(
            plan_id="COR_BAND_ROW",
            name_zh="弹力带划船 + 肩胛后缩",
            category=PlanCategory.STRENGTHENING,
            target_fault_codes=("PU_ELBOW_FLARE",),
            goal="强化肩胛稳定与上背力量，改善俯卧撑时肩关节代偿",
            instructions=(
                "弹力带固定于胸口高度，双手握住两端",
                "先做肩胛后缩，再屈肘把带子拉向身体",
                "肘部沿体侧走，不要外展抬起",
                "缓慢还原，保持肩胛控制",
            ),
            key_cues=("先收肩胛再拉", "肘部贴着身体走"),
            dosage=Dosage(),
            equipment=("弹力带",),
            difficulty=2,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("初中", "高中"),
            contraindications=("肩关节疼痛或不稳时需教师评估后使用",),
            evidence_refs=(EVIDENCE["nsca_youth"],),
        ),
        CorrectionPlan(
            plan_id="COR_TEMPO_SQUAT",
            name_zh="慢速节奏徒手深蹲",
            category=PlanCategory.MOTOR_RETRAINING,
            target_fault_codes=("TEMPO_UNCONTROLLED", "INSUFFICIENT_DEPTH", "EXCESSIVE_TRUNK_LEAN"),
            goal="用节奏强制重建离心控制与全程对齐",
            instructions=(
                "双脚与肩同宽，脚尖略外展",
                "用 3 秒缓慢下蹲，在最低点停 1 秒",
                "用 2 秒匀速站起，全程膝盖对准脚尖",
                "每一次都按这个节奏，不追求次数",
            ),
            key_cues=("三秒下，一秒停，两秒起", "慢就是快"),
            dosage=Dosage(),
            equipment=(),
            difficulty=1,
            age_min=_YOUTH[0],
            age_max=_YOUTH[1],
            grade_fit=("小学高年级", "初中", "高中"),
            contraindications=("下蹲中出现疼痛时减小幅度",),
            evidence_refs=(EVIDENCE["squat_depth"],),
        ),
    )


class PlanLibrary:
    """只读的方案库。

    Args:
        plans: 全部方案。重复的 ``plan_id`` 会在构造时报错 ——
            ``plan_id`` 会写进历史决策记录，重复会让「当时推荐了哪一套」无法追溯。
    """

    def __init__(self, plans: Sequence[CorrectionPlan]) -> None:
        index: dict[str, CorrectionPlan] = {}
        for plan in plans:
            if plan.plan_id in index:
                raise ValueError(f"方案编码重复：{plan.plan_id}")
            index[plan.plan_id] = plan
        self._index = index

    def __len__(self) -> int:
        return len(self._index)

    def by_id(self, plan_id: str) -> CorrectionPlan:
        try:
            return self._index[plan_id]
        except KeyError as exc:
            raise KeyError(f"方案不存在：{plan_id}") from exc

    def all(self) -> tuple[CorrectionPlan, ...]:
        return tuple(self._index.values())

    def pending_review(self) -> tuple[CorrectionPlan, ...]:
        """全部待核定方案。交付给体育专业成员时直接导出这一份。"""
        return tuple(p for p in self._index.values() if p.status is PlanStatus.DRAFT)

    def for_faults(
        self,
        fault_codes: Iterable[str],
        *,
        age: int,
        available_equipment: Iterable[str] = (),
        include_unreviewed: bool = False,
        limit: int | None = None,
    ) -> tuple[CorrectionPlan, ...]:
        """按错误码检索可用方案。

        候选按「覆盖了多少个目标错误码」降序排列 —— 一次给三个方案时，
        优先给覆盖面最广的那几个，比按困难度排序更符合「先解决主要问题」的意图。

        Args:
            include_unreviewed: 是否包含未核定方案。**默认 False**：
                未核定的方案不能作为建议推送给用户。研究或内部评审场景可置 True。
        """
        wanted = set(fault_codes)
        eligible = [
            plan
            for plan in self._index.values()
            if (plan.status is PlanStatus.ACTIVE or include_unreviewed)
            and plan.status is not PlanStatus.DEPRECATED
            and plan.suitable_for_age(age)
            and plan.requires_equipment(available_equipment)
            and not wanted.isdisjoint(plan.target_fault_codes)
        ]
        eligible.sort(
            key=lambda p: (
                -len(wanted.intersection(p.target_fault_codes)),
                p.difficulty,
                p.plan_id,
            )
        )
        return tuple(eligible[:limit] if limit is not None else eligible)

    def for_faults_with_review_fallback(
        self,
        fault_codes: Iterable[str],
        *,
        age: int,
        available_equipment: Iterable[str] = (),
        limit: int | None = None,
    ) -> tuple[tuple[CorrectionPlan, ...], bool]:
        """检索方案；若无已核定方案则退回未核定方案。

        返回 ``(方案, 是否含未核定)``。

        **为什么需要这条路径**：种子方案库全部处于 ``draft`` 状态，严格按
        「只给已核定方案」执行的话，体育专业成员完成核定之前系统给不出任何建议 ——
        对用户是零价值，对演示是空白页。

        折中不是放宽门槛，而是**如实标注**：给出候选动作，同时把「剂量待核定」
        写进文案。用户得到的是「有几个方向可能对你有帮助，具体练多少请老师确认」，
        而不是一个来源不明的训练处方，也不是一片空白。

        调用方拿到的 ``含未核定`` 标志必须传导到响应里（``PlanChoice.dose_note``），
        不能中途丢掉 —— 丢了就变成了冒充已核定。
        """
        reviewed = self.for_faults(
            fault_codes,
            age=age,
            available_equipment=available_equipment,
            include_unreviewed=False,
            limit=limit,
        )
        if reviewed:
            return reviewed, False
        fallback = self.for_faults(
            fault_codes,
            age=age,
            available_equipment=available_equipment,
            include_unreviewed=True,
            limit=limit,
        )
        return fallback, bool(fallback)


def default_library() -> PlanLibrary:
    """内置的种子方案库。"""
    return PlanLibrary(_plans())


__all__ = [
    "EVIDENCE",
    "CorrectionPlan",
    "Dosage",
    "PlanCategory",
    "PlanLibrary",
    "PlanStatus",
    "default_library",
]
