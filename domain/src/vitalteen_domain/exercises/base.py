"""动作定义的共享基础设施。

本模块提供四样东西，供各动作定义（``squat.py`` 等）复用：

- :class:`Calibration` / :class:`Calibrator` —— 采集本人的站立基线
- :class:`TrackingConfig` —— 全部**工程默认值**（非体育阈值，见设计文档 §7.1）
- :class:`BaselineAdjustedThresholds` —— 把「相对基线的增量阈值」换算成绝对阈值
- :class:`RepTracker` —— 把「逐帧特征流」切成一个个 rep 窗口

**为什么需要个体化基线**

「躯干前倾 30 度」对不同人是不同的含义：腿长比例大的人天然更前倾，踝背屈受限的人
脚跟天然更容易离地。用绝对阈值会把体型差异误判成动作缺陷。因此这类判据必须拿
**相对本人站立基线的增量**去比（设计文档 §5.2 就是这样定义 ``EXCESSIVE_TRUNK_LEAN`` 的）。

**分段与判定的分工（关键）**

状态机只负责**分段**：这一帧属于哪个相位、这一段算不算一次完整动作。它用的阈值全部是
工程参数（「膝角弯曲超过 45 度才算一次下蹲尝试」）。至于「蹲得够不够深」，是规则引擎
的职责，用的是体育阈值。

两者绝不能混：如果分段也用体育阈值，那么一个未核定的数字会同时决定「是否计数」和
「是否扣分」，出问题时你分不清是分段错了还是判定错了。
"""

from __future__ import annotations

import statistics
from dataclasses import dataclass, field, replace

from ..features import CameraView, FeatureExtractor, FrameFeatures
from ..pose import PoseFrame
from ..rules import Phase, RepWindow, Rule, RuleEngine, SetSummary
from ..state_machine import StateMachine, Transition
from ..thresholds import Threshold, ThresholdTable


#: 允许被基线偏移引用的量的名字集合。各动作定义在 ``threshold_offsets`` 里
#: 用这些名字引用基线量：把「用哪个基线」与「加多少」分开表达，动作定义才能
#: 声明式地声明依赖，而不必在 build 函数里手写一堆 ``replace``。
#:
#: 每个名字**必须与 :class:`Calibration` 的同名字段一致** ——
#: :func:`_calibration_offsets` 靠 ``getattr(calibration, name)`` 取值，
#: 名字对不上就是一个静默的 ``AttributeError``（或者更糟：取到一个别的量）。
BASELINE_KEYS = frozenset(
    {"trunk_lean", "heel_rise_ratio", "knee_angle", "leg_spread", "foot_height"}
)

#: 各基线量从哪些特征、怎么算出来。**这是唯一的映射处**（Dart 侧对应
#: ``Calibrator`` 内部那张同名表），加一个基线量只动这一个字典。
#:
#: 注意这里不是「按特征平铺」：``knee_angle`` 是左右两个特征的**均值**，
#: ``trunk_lean`` 取**绝对值**（左倾右倾都是倾），另外两个取原值。
#: 于是第三个元素记的是「怎么聚合」而不是特征码 —— 一个基线量可以从多个
#: 特征来，也可以只有一个。
_BASELINE_SOURCES: dict[str, tuple[tuple[str, ...], str]] = {
    "knee_angle": (("knee_angle_L", "knee_angle_R"), "mean"),
    "trunk_lean": (("trunk_lean",), "abs"),
    "heel_rise_ratio": (("heel_rise_ratio_L",), "raw"),
    "leg_spread": (("leg_spread_ratio",), "raw"),
    "foot_height": (("foot_height_ratio",), "raw"),
}

#: 标定**默认**要求采到的基线量。深蹲与立定跳远都不传 ``required``，
#: 所以走的正是这一组 —— 它与加 ``leg_spread`` 之前那份硬编码的四个特征
#: **逐值等价**（左右膝角均值、躯干倾角绝对值、左脚跟抬升比）。
#:
#: 为什么单列一个常量：它同时是「默认行为没变」这条断言的对象
#: （``domain/tests/test_calibration_seam.py``）。写在 ``__init__`` 的
#: 默认参数里就没法在测试里指着它说「就是这三个」。
DEFAULT_REQUIRED_BASELINES = frozenset({"knee_angle", "trunk_lean", "heel_rise_ratio"})

#: 每一组基线集都必须有的量。这两个特征在任何机位下都算得出
#: （``knee_angle_*`` 与 ``trunk_lean`` 都没有 ``views`` 门控），
#: 所以它们可以是被无条件信任的；而它们同时也是 :class:`Calibration` 上
#: 两个**非空**的字段。把这条不变式写成构造期检查，缺席就是当场炸 ——
#: 而不是等到某条规则去读一个 ``None``。
_ALWAYS_REQUIRED_BASELINES = frozenset({"knee_angle", "trunk_lean"})


def _collect_baseline(name: str, features: FrameFeatures) -> float | None:
    """从一帧里算出某个基线量。任一所需特征不可用则返回 ``None``。

    返回 ``None`` 表示「这一帧不知道」，**不是「这一帧是 0」** ——
    调用方必须整帧跳过，不能拿 0 顶上（见 :class:`Calibrator` 的说明）。
    """
    try:
        codes, aggregation = _BASELINE_SOURCES[name]
    except KeyError:  # pragma: no cover - 由 __init__ 的前置检查挡住
        raise ValueError(f"未知的基线量：{name}") from None

    values = [features.get(code) for code in codes]
    if any(value is None for value in values):
        return None

    if aggregation == "mean":
        return sum(values) / len(values)  # type: ignore[arg-type]
    if aggregation == "abs":
        return abs(values[0])  # type: ignore[arg-type]
    return values[0]


@dataclass(frozen=True, slots=True)
class Calibration:
    """本人站立基线。基线类规则以此为参照做个体化比较。

    标定采集哪几个量**随动作而变**（见 :data:`DEFAULT_REQUIRED_BASELINES`），
    所以不是每个动作都填满全部字段。缺席的量是 ``None``，**不是 0** ——
    「不知道」和「是零」在个体化阈值里是两回事，混起来会算出一条谁也不认识的线。

    Attributes:
        knee_angle: 站立膝角（左右均值），通常 170–180 度。**每个动作都有**：
            它在任何机位下都算得出（该特征没有 ``views`` 门控）。
        trunk_lean: 站立躯干倾角绝对值（度）。同上，**每个动作都有**。
        heel_rise_ratio: 站立脚跟抬升比（接近 0；鞋子与站姿会带来个体差异）。
            只在侧视/45° 下采得到 —— 判「脚跟离地」的动作才要它。
        frames: 采集所用的有效帧数，供质量评估。
        leg_spread: 站立分腿比（两踝横向间距 / 肩宽）。只在正面机位下有定义，
            判「开合到不到位」的动作才要它。**字段名要与
            :data:`BASELINE_KEYS` 里的名字一致** —— 那边靠 ``getattr`` 取值。
        foot_height: 站立时双脚脚尖高出画面下缘的高差（以躯干长归一）。
            只在侧视/45° 下有定义，判「人有没有离地」的动作（跳绳）才要它。
            **绝对值跨组没有意义**（机位高低决定画面下缘离脚尖有多远），
            它的唯一用途就是当零点：跳绳那三条分段线全部记成它的增量。

            跳绳**不采**「站立时左右脚尖的高度差」（那是 ``foot_gap_ratio``）：
            它没有第二条用处 —— 站稳的人左右脚尖本来就等高（理论上是 0），
            而它唯一可能的用途（给 ``ROPE_SINGLE_LEG`` 一条个体化基线）恰恰会让
            阈值变成「0 × 系数 ≈ 0」，于是那条规则永远命中。多采一个没人读的
            基线，换来的只是标定期多一处可能采不满的地方。
    """

    knee_angle: float
    trunk_lean: float
    heel_rise_ratio: float | None
    frames: int
    # 带默认值的字段必须排在最后，否则 dataclass 直接报错。
    leg_spread: float | None = None
    foot_height: float | None = None


class Calibrator:
    """从一段站立姿态中采集基线。

    用**中位数**而非均值：校准期用户可能说话、晃动、被路人挡一下，均值会被个别
    离群帧拖偏，中位数不会。

    特征不可用的帧直接跳过、不参与统计 —— 它们不是「膝角为 0 的帧」，而是「不知道
    膝角是多少的帧」，混进中位数里会污染基线（铁律二）。

    **采哪几个量随动作而变**（``required``）。开合跳跑正面机位，那里
    ``heel_rise_ratio_L`` 声明了 ``views: [sagittal, oblique45]``，恒不可用 ——
    固定四个特征的话它的 :meth:`feed` 永远返回 ``None``：标定条卡住不动、
    **不报任何错**、永远进不了计数。这是最难查的一类坏法，所以门槛必须
    由调用方声明，而不是写死在这里。

    ``required`` 收的是**基线量的名字**（:data:`BASELINE_KEYS` 的成员），
    不是特征码。用字符串而不是枚举是 Python 侧既有约定的延续（Dart 侧用枚举，
    那边字符串拼错不会在编译期报错）；这里由 :meth:`__init__` 当场校验，
    拼错的名字是一个立刻抛出的 ``ValueError``，而不是「标定静默卡死」。
    """

    def __init__(
        self,
        *,
        min_frames: int = 15,
        required: frozenset[str] = DEFAULT_REQUIRED_BASELINES,
    ) -> None:
        if min_frames < 1:
            raise ValueError("min_frames 必须 >= 1")

        unknown = frozenset(required) - BASELINE_KEYS
        if unknown:
            raise ValueError(f"未知的基线量：{sorted(unknown)}")
        missing = _ALWAYS_REQUIRED_BASELINES - frozenset(required)
        if missing:
            raise ValueError(f"这些基线量每个动作都要：{sorted(missing)}")

        self._min_frames = min_frames
        self._required = frozenset(required)
        self._samples: dict[str, list[float]] = {name: [] for name in self._required}
        self._result: Calibration | None = None

    @property
    def required(self) -> frozenset[str]:
        """这一台标定器要采哪几个量。缺帧时拿它跟 ``ActionSpec`` 对照着查。"""
        return self._required

    @property
    def is_ready(self) -> bool:
        return self._result is not None

    @property
    def calibration(self) -> Calibration | None:
        return self._result

    def feed(self, features: FrameFeatures) -> Calibration | None:
        """喂入一帧。就绪后返回基线，否则返回 ``None``。

        **``required`` 里任何一个量这一帧算不出来，整帧丢弃** —— 不是「跳过那个量、
        别的照收」。混着收会让各个量的帧数不一样，于是它们的中位数来自不同的
        时间窗；而这里每一帧都是一个静止站姿，多收少收没有收益，只有不一致。
        """
        if self._result is not None:
            return self._result

        samples: dict[str, float] = {}
        for name in self._required:
            value = _collect_baseline(name, features)
            if value is None:
                return None
            samples[name] = value

        for name, value in samples.items():
            self._samples[name].append(value)

        # 每个量的列表都等长（上面那一帧缺任何一个就整帧丢弃），所以拿
        # ``knee_angle`` 的帧数当代表 —— 它在 ``_ALWAYS_REQUIRED_BASELINES``
        # 里，一定存在。
        frames = len(self._samples["knee_angle"])
        if frames < self._min_frames:
            return None

        self._result = Calibration(
            knee_angle=statistics.median(self._samples["knee_angle"]),
            trunk_lean=statistics.median(self._samples["trunk_lean"]),
            heel_rise_ratio=self._median_or_none("heel_rise_ratio"),
            frames=frames,
            leg_spread=self._median_or_none("leg_spread"),
            foot_height=self._median_or_none("foot_height"),
        )
        return self._result

    def _median_or_none(self, name: str) -> float | None:
        """没采这个量就返回 ``None``。**不是 0** —— 见 :class:`Calibration`。"""
        values = self._samples.get(name)
        return statistics.median(values) if values else None

    def reset(self) -> None:
        for values in self._samples.values():
            values.clear()
        self._result = None


@dataclass(frozen=True, slots=True)
class TrackingConfig:
    """全部**工程默认值**，与体育阈值无关（设计文档 §7.1）。

    这些是技术选择，工程师可以调；它们不参与扣分，也不该出现在
    ``shared/thresholds/`` 里。改它们只需要看回归测试，无需体育专业成员核定。

    Attributes:
        min_bend_deg: **分段**参数 —— 下蹲类动作的进入线：膝角相对站立基线弯曲
            超过这么多度，才算进入蹲位。这不是质量判断：蹲得浅一样算进入，
            只是会被该动作的深度类规则判为不足。取多少由动作决定 ——
            深蹲取 45（它的 BOTTOM 线），立定跳远取 25（有意下蹲线）。
        standing_hysteresis_deg: 站立段与下蹲段之间的滞回带宽，防止在边界抖动时
            反复跨越导致重复计数。
        max_rep_frames: 一次 rep 的帧数上限。超过则丢弃该段并重新同步 ——
            用户走开、镜头被挡、或状态机卡住时不应无限期挂着一个未完成的 rep。
            立定跳远取 120（≈4 秒）而不是深蹲的 300：真跳一次约 60 帧，而
            「蹲一下又站起来但没跳」的假动作会停在 FLIGHT 上，要等这么久才被
            ``RepTracker`` 复位 —— 停着的每一帧界面上都显示着一个错误的状态词。
        flight_extension_deg: 立定跳远：近于完全伸直的线，读作「蹬直 ≈ 离地」。
            **这是代理量**：单目无世界坐标，没有任何特征能证明人真的离了地
            （设计文档附录 A）。它同时是**漏计的旋钮** —— 状态机没有
            「起跳了但没蹬直」那条边（守卫看不见时间），蹬不到这条线的跳
            不会被计数。真机上发现漏计偏多，调大它，不要加边。
        landing_flex_deg: 立定跳远：落地进入线。**必须 >**
            ``standing_hysteresis_deg``，否则它与「回到站立」的退出线撞在一起，
            LAND 会一闪而过。
        landing_hip_floor: 立定跳远：收腿剔除门槛，与特征 ``hip_height_ratio``
            同量纲（躯干长归一）。收腹举腿是正规技术，腾空中膝盖会折到胸口，
            该特征变负；不挡的话 ``FLIGHT → LAND`` 会在半空中触发，
            落地缓冲那条规则就**永远不再触发**。用绝对门槛而不是本人站立值的
            比例：该特征已经用躯干长归一过，个体差异在这条算式里已经消掉了。
        spread_enter_delta: 开合跳：进入线 —— 比本人站立时多开这么多，算
            「开起来了」。**单位是比值，不是度**（``leg_spread_ratio`` 已用肩宽
            归一，镜头远近与体型都约掉了）。**必须大于** ``spread_hysteresis``，
            否则 CLOSED 与 OPENING 之间没有起步空间，腿在边界上抖一下就会
            逐帧来回跳。
        spread_full_delta: 开合跳：到位线 —— 比本人站立时多开这么多，算
            「开到位了」。它同时是**计数门槛**（OPEN 是 ``bottom_state``）与
            两条回弹边的守卫。只开到进入线与到位线之间的跳不算一次。
        spread_hysteresis: 开合跳：回到站立态的容差带 —— 与本人站立基线相差
            不超过这么多，算「合回来了」。**两条落到 CLOSED 的边共用它**
            （开一半的回退、合拢后的封存）；它同时是 OPENING 的退出间距
            （``spread_enter_delta`` − 本值），调大它会缩小起步空间。
        pushup_top_deg: 俯卧撑：回到顶部的进入线，肘角大于此值算「撑起来了」。
            它同时是**计数门槛** —— 没撑到这条线的一次会停在 UP 直到超时丢弃，
            而不是被计成一次。取 165（离伸直 15°）是为了容纳测量噪声。
        pushup_depth_deg: 俯卧撑：进入最低点的线，肘角小于或等于此值算「到底了」。
            同样是计数门槛而不是质量判断 —— 只下到 110° 的人也进 BOTTOM，
            只是会被深度规则判为不足。
        situp_lie_ratio: 仰卧起坐：躺平线 —— 肩只比踝高这么点（比值）算
            「躺回垫上了」。单位是比值（特征 ``shoulder_height_ratio``）。
            **参照物是踝而不是画面**：踝在整组里贴在垫上不动，是唯一稳定的零点。
            实际读数：仰卧平躺约 0.1 以下（背弓使肩略高于垫），坐起途中约 0.5。
        situp_seat_ratio: 仰卧起坐：坐起线 —— 肩比踝高出这么多算「坐起来了」。
            它同时是**计数门槛**（SEATED 是 ``resting_state``，回到它才封存一次）。
            **这个量有物理上界，而且上界不是「坐直」**：臀贴在垫上时肩绕髋转，
            比值 = 躯干与竖直方向的夹角余弦（推导见 ``situp.py`` 模块文档），
            1.0 恰好是「躯干严格竖直」那一个奇点，而国标的收势是前倾
            （肘触膝，前倾 30° 只有 0.87）。取 1.0 会让标准动作永远不被计数，
            而且**奖励那个正要被罚的错** —— 臀一离垫肩就被顶高，反而够得着线。
            所以取 0.75（躯干距竖直约 41° 以内）。
        situp_hysteresis: 仰卧起坐：躺平线两端的容差带。它同时是「离开躺平」的
            门槛（``situp_lie_ratio`` + 本值），所以调大它会同时压缩
            「坐起」与「躺平」之间的行程。
        rope_takeoff_ratio: 跳绳：起跳线 —— 脚尖比站立时高出这么多算「离地了」。
            三段里最高的一条。取 0.10 躯干长（成人躯干约 0.5 m，折合脚尖抬离
            地面约 5 cm），低于常见跳绳的腾空高度（10–20 cm）。
        rope_land_ratio: 跳绳：落地线 —— 脚尖回落到这个高度以下算「脚又碰上了地」。
            **必须小于** ``rope_takeoff_ratio``：两条线是同一个量的进入线与退出线，
            相等的话状态机会在腾空高度上反复跨越。留一半作间隔，是因为一次跳绳的
            腾空只持续零点几秒（20 帧上下），滞回带宽太大就追不上节奏。
        rope_settle_ratio: 跳绳：落地稳定线 —— 脚尖回落到几乎贴住站立线，算
            「缓冲结束、站回地面」。**必须小于** ``rope_land_ratio``。
            它标记的是这一跳的结束（``CUSHION → GROUND`` 那一步封存一次计数），
            而落地缓冲那一下膝盖会先屈后伸，脚尖高度在这期间还会小幅弹动 ——
            抓到「已经回到站姿高度」才封存，比抓到「刚刚触地」更不容易把一次跳
            切成两次。反过来它也是**漏计的旋钮**：落得不干净（比如一直踮着脚尖跳）
            的人可能永远回不到这条线，只能靠 ``max_rep_frames`` 超时收尾。
        pullup_hang_deg: 引体向上的「直臂悬垂线」—— 肘角回到这个值以上，才算回到
            悬垂位。它同时是**离开悬垂**的进入线（``HANG → PULLING``）与
            **回到悬垂**的封存线（``LOWERING → HANG``），两条边共用同一个数。
            165° 而不是 180°：挂在杠上时手臂本来就有一点弯（握杠、肩胛上旋），
            而 180° 是一个几乎取不到的奇异值 —— 取 180 会让一次都封存不了。
        pullup_top_deg: 引体向上的「顶部线」—— 肘角弯到这个值以下，才算拉到顶。
            它是 ``PULLING → TOP`` 的进入线，也是**计数门槛**（``bottom_state``），
            没拉到顶的那次不算一次。90° 比国标收势（下颌过杠）对应的肘角更宽松，
            这是刻意的：**计数不该用最脆弱的那条判据**。下颌过杠要读嘴点，
            而嘴是可见性最低的几个关键点之一；拿它当计数门槛的话，脸被上臂挡住时
            整组会一次都数不上且不报错。门槛用稳健的肘角，下颌过杠交给规则层判。

        ---- 平板支撑：支撑位的三条判据（两个量 + 一条肘角带）----

        这个动作与前面七个都不一样：它的 rep 是**一段时间**，而「在不在支撑位上」
        要同时看三件事 —— 身体放平了没有、体线直不直、撑地的那条手臂在不在位置。
        三条全是工程参数（怎么切段），不含体育阈值：「撑得够不够标准」由 ``plank.``
        前缀那三条规则判，两者刻意分开。

        **为什么必须三条一起看**：这条链上任何单独一条都会把别的东西读成支撑。
        站着的人体线也大致成一条直线（肩在髋上方、髋在踝上方，体线偏移 ≈ 0），
        光看体线会把站立读成支撑；趴着的人体线也直、也水平，光看这两个量会把
        「趴在地上」读成支撑。三条的合取才把站立、坐着、趴着都挡在外面 ——
        而**趴着这一点挡不干净**，那是一条写进 ``plank.py`` 文件头的边界。

        plank_lie_deg: 身体放平线 —— 躯干与竖直方向的夹角**大于**此值算「身体放平
            了」。这是把**站立**挡在支撑位外面那条判据：站着时 ``trunk_lean`` 只有
            几度，而支撑时躯干接近水平（≈90°）。取 60（而不是 80 上下）是为了容纳
            塌腰或撅臀时躯干整体倾斜 —— 那是规则要判的错，不该变成「这一下没数上」。
        plank_line_enter_ratio: 进入支撑位的体线容差 —— ``body_line_offset_ratio``
            的**绝对值**不超过它，算「肩髋踝大致成一条线」。单位是比值（该特征已用
            躯干长归一，正 = 髋更低 = 塌腰、负 = 撅臀）。它比资产表里那两条判定的
            阈值**宽得多**，这是刻意的 —— 同开合跳（``spread_full_delta`` 宽、
            ``jj.spread_min_ratio`` 严）：门槛只管「还在不在支撑位上」，塌了多少是
            规则的事。取得太严的后果是**规则反而看不到重犯**：塌腰一越线这一段就
            结束了，而结束处那几帧才是本该被那条规则逮住的证据。
        plank_line_exit_ratio: 离开支撑位的体线容差。**必须大于**
            ``plank_line_enter_ratio`` —— 两者之间是滞回带，没有它的话，髋在边界上
            抖一帧就会把一次支撑切成两段。
        plank_elbow_min_deg / plank_elbow_max_deg: 支撑带（肘角）的下沿与上沿 ——
            撑地那条手臂的肘角落在这一带里，才算「撑在前臂上」。**它不是质量判据**
            —— 同一条量上另有一对更严的体育阈值（``plank.elbow_angle_min/max``），
            那才是「肘角偏没偏离支撑位」。门槛宽、判据严，两者之间的那一段就是规则
            有活干的地方。**上沿必须离「手臂伸直」（≈180°）足够远**：站着的人肘角
            接近 180，上沿一旦够到那里，光靠肘角就分不出「撑着」与「站着」。
            这条不变式在 ``build_plank`` 里当场断言。
    """

    camera_view: CameraView = "sagittal"
    visibility_threshold: float = 0.5
    calibration_frames: int = 15

    min_bend_deg: float = 45.0
    standing_hysteresis_deg: float = 8.0

    min_dwell_frames: int = 3
    vote_window: int = 5
    vote_required: int = 4

    max_rep_frames: int = 300

    flight_extension_deg: float = 4.0
    landing_flex_deg: float = 12.0
    landing_hip_floor: float = 0.2

    # ---- 开合跳：分腿幅度的分段线 ----
    #
    # 三个值全是工程参数（怎么切段），不含体育阈值 ——「开合到不到位」由
    # ``jj.spread_min_ratio`` 那条规则判，两者刻意分开。三条线都**相对本人站立
    # 基线**：自然站立与并腿站立的绝对值差着 0.5 上下，用绝对线等于对站姿挑人。
    spread_enter_delta: float = 0.30
    spread_full_delta: float = 0.80
    spread_hysteresis: float = 0.08

    # ---- 俯卧撑：肘角的分段线 ----
    #
    # 单位是度，而且是**绝对值**（不是相对基线的增量）。之所以能用绝对值：
    # 肘角的「伸直」有一个解剖学上的固定参照 —— 180°。深蹲的站立基线之所以
    # 必须个体化，是因为「站直」的膝角因人而异；「手臂伸直」不是。
    #
    # 两者都是工程参数（怎么切段），不含体育阈值 ——「下得够不够低、撑得够不够直」
    # 由 ``pu.min_depth_elbow_angle`` 与 ``pu.top_extension_elbow_angle`` 两条规则判。
    pushup_top_deg: float = 165.0
    pushup_depth_deg: float = 100.0

    # ---- 仰卧起坐：上身高度的分段线 ----
    #
    # 单位同样是比值（``shoulder_height_ratio``：肩比踝高多少，以躯干长归一）。
    # **参照物是踝而不是画面** —— 踝在整组里贴在垫上不动，是唯一稳定的零点；
    # 拿画面当参照就会把「人整体挪了挪」读成「上身起来了」。
    #
    # 三条都是工程参数（怎么切段），不含体育阈值 ——「肩胛有没有贴垫」
    # 「髋有没有离垫」由 ``su.`` 前缀那几条规则判，两者刻意分开。
    #
    # 实际读数（45° 机位下整体偏大约 1.4 倍，见 ``features.py`` 的
    # ``shoulder_height_ratio``）：仰卧平躺约 0.1 以下，坐起到肩在髋正上方
    # 约 1.0 上下。这些数是**按典型体型估的**，等真机数据再收。
    situp_lie_ratio: float = 0.25
    situp_seat_ratio: float = 0.75
    situp_hysteresis: float = 0.06

    # ---- 坐位体前屈：上身前折的两条分段线 ----
    #
    # 单位是**度**，量的是 ``hip_angle_L``（肩—髋—膝那个夹角）。
    # 坐直（躯干竖直、大腿水平）时它是 90°，上身向前折下去就变小。
    #
    # **它是绝对角度，不是相对基线的增量** —— 与深蹲那条正相反。理由是同一个
    # 姿势对每个人的读数是一样的：大腿水平、躯干竖直，谁坐都是 90°，
    # 不存在「腿长大的人天然前倾」那类个体差异。所以这里没有基线偏移
    #（见 ``sit_reach.py`` 文件头的「阈值分工」）。
    sit_reach_upright_deg: float = 75.0
    sit_reach_holding_deg: float = 55.0
    sit_reach_hysteresis_deg: float = 8.0

    # ---- 跳绳：脚尖离地的三条分段线 ----
    #
    # 单位是比值（``foot_height_ratio``：脚尖高出画面下缘多少，以躯干长归一），
    # 而且**三条全部是相对本人站立基线的增量**，不是绝对值。
    #
    # 之所以必须相对基线：画面上下的绝对值由机位高度决定（手机架在腰高还是
    # 胸口高，同一个站姿的读数能差一大截），拿它当门槛会变成「手机架得对不对」
    # 的判据。增量把这些全约掉了，只剩下「比站着的时候高了多少」。
    #
    # 跳绳的标定姿势因此与别的动作不同：必须**站稳在地上**（这是唯一一个
    # 基线本身就代表「接触地面」的动作）。
    rope_takeoff_ratio: float = 0.10
    rope_land_ratio: float = 0.05
    rope_settle_ratio: float = 0.02

    pullup_hang_deg: float = 165.0
    pullup_top_deg: float = 90.0

    plank_lie_deg: float = 60.0
    plank_line_enter_ratio: float = 0.45
    plank_line_exit_ratio: float = 0.60
    plank_elbow_min_deg: float = 50.0
    plank_elbow_max_deg: float = 130.0


class BaselineAdjustedThresholds:
    """查表时把「相对基线的增量阈值」换算成绝对阈值的包装。

    规则引擎只会做「指标 vs 阈值」的直接比较，而躯干前倾、脚跟抬升这类判据是
    **相对本人站立基线的增量**。与其给通用引擎加一个「基线偏移」的概念（那会污染
    数据模型，且基线只有动作层才知道），不如在阈值这一层做换算 ——
    引擎保持对基线一无所知，个体化逻辑集中在动作定义里。

    只实现 :class:`RuleEngine` 用到的那部分接口：``get(key)``。
    """

    def __init__(self, inner: ThresholdTable, offsets: dict[str, float]) -> None:
        self._inner = inner
        self._offsets = dict(offsets)

    @property
    def version(self) -> str:
        return self._inner.version

    def get(self, key: str) -> Threshold:
        threshold = self._inner.get(key)
        offset = self._offsets.get(key)
        if offset is None:
            return threshold
        return replace(threshold, value=threshold.value + offset)


@dataclass(slots=True)
class _Span:
    """一段连续处于同一状态的帧区间（闭区间，索引相对 rep 缓冲）。"""

    state: str
    start: int
    end: int


class RepTracker:
    """驱动状态机，把帧流切成 rep 窗口。

    职责边界：本类只管**切分**，不做任何质量判断。切好的 :class:`RepWindow`
    交给规则引擎去评错误。

    **只有到达过 ``bottom_state`` 的段落才算一次有效 rep。** 否则「弯 10 度再直起来」
    也会被计成一次深蹲。这个门槛同时保证了已封存的 rep 里必定存在 BOTTOM 相位，
    规则不会因为拿不到底部窗口而退化到整段评估。
    """

    def __init__(
        self,
        machine: StateMachine,
        *,
        resting_state: str,
        bottom_state: str,
        config: TrackingConfig,
        state_to_phase: dict[str, Phase],
        loss_recovery: dict[str, str] | None = None,
    ) -> None:
        if bottom_state == resting_state:
            raise ValueError("bottom_state 不能等于 resting_state")
        self._machine = machine
        self._resting = resting_state
        self._bottom = bottom_state
        self._config = config
        self._state_to_phase = dict(state_to_phase)
        self._loss_recovery = dict(loss_recovery or {})

        self._buffer: list[FrameFeatures] = []
        self._spans: list[_Span] = []
        self._current_start = 0
        self._rep_start: int | None = None
        self._reached_bottom = False
        self._discarded = 0

        self.completed: list[RepWindow] = []
        """已封存的 rep 窗口，按完成顺序。"""

    @property
    def machine(self) -> StateMachine:
        return self._machine

    @property
    def current_state(self) -> str:
        return self._machine.state

    @property
    def discarded_reps(self) -> int:
        """从未到达底部而被丢弃的段落数。可用于提示用户「动作幅度太小」。"""
        return self._discarded

    def feed(self, features: FrameFeatures) -> RepWindow | None:
        """喂入一帧。若本帧完成了一次有效 rep，返回其窗口，否则返回 ``None``。"""
        update = self._machine.update(features.as_signals(), features.timestamp_ms)

        # 等待期：缓冲区不保留历史，避免长时间站立把内存吃满，也让 rep 起点
        # 自然落在「离开站立态」的那一帧上。
        if self._rep_start is None:
            self._buffer.clear()
            self._spans.clear()
            if update.changed and update.left == self._resting:
                self._rep_start = 0
                self._current_start = 0
                self._reached_bottom = False
                self._buffer.append(features)
                # **这一帧也要记「到过底部」。** 上面那条「不保留历史」管的是
                # 缓冲区，不管记账：起点的这一帧同样是一次真实的状态进入。
                #
                # 漏掉它会静默毁掉一类动作定义 —— **resting_state 的下一步就是
                # bottom_state 的那一类**（跳绳：``GROUND → AIR``，``AIR`` 就是
                # bottom_state）。那一步正好落在这一帧上，于是每一帧都记不到底部，
                # 每一次 ``_seal`` 都走「没到过底部」的分支：**整组一次都不计数、
                # 全部计进 discarded_reps**，而 HUD 上的状态词一直是正确的。
                # 跳绳之前，五个动作都没有这条边（它们都要先经过一个过渡态），
                # 所以这处遗漏一直没有暴露出来。
                #
                # 反过来，这条边存在时，``bottom_state`` 的含义依然成立：中途没进过
                # ``AIR`` 的那些段（起跳一半又落回）仍然会被丢弃。
                if update.entered == self._bottom:
                    self._reached_bottom = True
            return None

        index = len(self._buffer)
        self._buffer.append(features)

        if update.changed:
            assert update.left is not None  # 引擎契约：changed=True 时必非 None
            self._spans.append(_Span(update.left, self._current_start, index - 1))
            self._current_start = index
            if update.entered == self._bottom:
                self._reached_bottom = True
            if update.entered == self._resting:
                return self._seal(index)

        if index > self._config.max_rep_frames:
            self._abandon()
        return None

    def recover_from_loss(self) -> bool:
        """人从一次丢失里回来了（不是一帧坏数据，是整段不在画面里）。

        按 :attr:`ActionDefinition.loss_recovery` 把停住的状态落到它该去的地方，
        返回是否真的动过。**必须在喂这一帧之前调用** —— 重同步的作用是让
        「这一帧该被读成什么」从下一帧起生效。

        离开画面的那几帧**不进缓冲区**：它们不是「姿态未知的帧」，是**不存在的帧**。
        拿最后见过的姿态去补，等于替用户编了一段动作。
        """
        if self._rep_start is None:
            return False  # 不在一次 rep 里，没有可救的东西
        target = self._loss_recovery.get(self._machine.state)
        if target is None:
            return False

        # 先给当前这一段收尾，再开新的一段。不收尾的话，重同步之后的帧会被记进
        # 旧状态的区间里，``_phase_bounds`` 拿到的相位就是错的 —— 而错相位不报错，
        # 只会让规则去评一段不属于它的帧。
        self._spans.append(_Span(self._machine.state, self._current_start, len(self._buffer) - 1))
        self._current_start = len(self._buffer)
        self._machine.reset(target)
        return True

    # ---- 内部 ----

    def _reset_rep_state(self) -> None:
        self._buffer.clear()
        self._spans.clear()
        self._current_start = 0
        self._rep_start = None
        self._reached_bottom = False

    def _abandon(self) -> None:
        """放弃当前未完成的 rep 并重新同步。

        不计数、不产出窗口 —— 一次被中途打断的动作没有可评价的语义。
        """
        self._discarded += 1
        self._reset_rep_state()
        self._machine.reset(self._resting)

    def _seal(self, index: int) -> RepWindow | None:
        frames = tuple(self._buffer[: index + 1])
        bounds = self._phase_bounds()
        reached = self._reached_bottom
        self._reset_rep_state()

        if not frames or not reached:
            # 没到过底部：不是一次下蹲，不计入。机器已经回到站立态，继续等下一段。
            self._discarded += 1
            return None

        window = RepWindow(index=len(self.completed) + 1, frames=frames, phase_bounds=bounds)
        self.completed.append(window)
        return window

    def _phase_bounds(self) -> dict[Phase, tuple[int, int]]:
        """把状态区间映射成相位区间。

        rep 缓冲的起点就是「离开站立态」那一帧，因此区间索引相对缓冲起点即为
        相对 rep 起点，无需再做平移。
        """
        bounds: dict[Phase, tuple[int, int]] = {}
        for span in self._spans:
            phase = self._state_to_phase.get(span.state)
            if phase is None or phase in bounds:
                # 同一相位在一次 rep 内出现多段时取首段：正常动作不会重复进入，
                # 重复出现说明动作被打断，取首段比取末段更保守。
                continue
            if span.end >= span.start >= 0:
                bounds[phase] = (span.start, span.end)
        return bounds

    def reset(self) -> None:
        self._reset_rep_state()
        self.completed.clear()
        self._discarded = 0
        self._machine.reset()


@dataclass(frozen=True, slots=True)
class ActionDefinition:
    """一个动作的完整定义。

    动作差异全部封装在这里：新增动作 = 新增一个定义，不改引擎（设计文档 §4.1）。
    """

    code: str
    name_zh: str
    camera_view: CameraView
    states: tuple[str, ...]
    resting_state: str
    bottom_state: str
    transitions: tuple[Transition, ...]
    rules: tuple[Rule, ...]
    state_to_phase: dict[str, Phase]
    threshold_offsets: dict[str, float]

    loss_recovery: dict[str, str] = field(default_factory=dict)
    """长丢失后的重同步：停在这些状态上时，该落到哪个状态去。

    **要解决的问题**：人出画时状态机停在哪儿是随机的。立定跳远出画多半发生在
    腾空那几帧，可「蹬直」这条线（相对站立基线只差 4°）未必已经跨过去 ——
    于是状态机停在 LAUNCH。人回来时蹲下，这一步被读成**回蹲**（LAUNCH→PREP），
    站直又把 PREP 推回 LAUNCH、再推进 FLIGHT，然后停在 FLIGHT 上等超时。
    一次真跳变成一次丢弃，而且**一次能见的落地被白白扔掉**。

    **立定跳远只登记 ``LAUNCH → FLIGHT`` 一条**，理由是这条最保守：
    它没有让任何一次未见过的落地变成分数，只是把「蹬伸那几帧没被看见」
    当成「人已经离地」—— 而离地之后**仍然要靠看得见的蹲下才算落地**。

    默认空：深蹲这一类动作的人不会离开原地，没有需要重同步的中途态。
    """

    @property
    def phase_of(self) -> dict[str, Phase]:
        return dict(self.state_to_phase)


class ActionRunner:
    """把「帧流 → 特征 → 状态机 → rep 窗口 → 错误判定」串成一条流水线。

    这是应用层与决策层之间的门面：手机端在标定完成后构造一个 runner，
    之后每帧调 :meth:`feed`，一组做完调 :meth:`finish_set` 拿汇总。
    """

    def __init__(
        self,
        definition: ActionDefinition,
        *,
        thresholds: ThresholdTable,
        calibration: Calibration,
        config: TrackingConfig | None = None,
    ) -> None:
        self._definition = definition
        self._config = config or TrackingConfig(camera_view=definition.camera_view)
        self._extractor = FeatureExtractor(
            visibility_threshold=self._config.visibility_threshold,
            camera_view=definition.camera_view,
        )
        self._engine = RuleEngine(
            definition.rules,  # type: ignore[arg-type]
            BaselineAdjustedThresholds(
                thresholds,
                _calibration_offsets(definition, calibration),
            ),  # type: ignore[arg-type]
        )
        self._tracker = RepTracker(
            StateMachine(
                initial_state=definition.resting_state,
                transitions=definition.transitions,
                min_dwell_frames=self._config.min_dwell_frames,
                vote_window=self._config.vote_window,
                vote_required=self._config.vote_required,
            ),
            resting_state=definition.resting_state,
            bottom_state=definition.bottom_state,
            config=self._config,
            state_to_phase=definition.state_to_phase,
            loss_recovery=definition.loss_recovery,
        )

    @property
    def current_state(self) -> str:
        return self._tracker.current_state

    @property
    def rep_count(self) -> int:
        return len(self._tracker.completed)

    @property
    def discarded_reps(self) -> int:
        return self._tracker.discarded_reps

    def feed(self, frame: PoseFrame) -> RepWindow | None:
        """喂入一帧原始姿态。完成一次有效 rep 时返回其窗口。"""
        return self._tracker.feed(self._extractor.extract(frame))

    def recover_from_loss(self) -> bool:
        """人从一次丢失里回来了。见 :meth:`RepTracker.recover_from_loss`。

        **在 :meth:`feed` 那一帧之前调**：它改的是「接下来这一帧该被读成什么」。
        """
        return self._tracker.recover_from_loss()

    def finish_set(self) -> SetSummary:
        """结束本组，返回组级判定汇总（决策层的输入）。"""
        return self._engine.evaluate_set(self._tracker.completed)

    @property
    def windows(self) -> tuple[RepWindow, ...]:
        """已封存的 rep 窗口，按完成顺序。

        逐次明细（每一次犯了什么错、偏离多少）只能从这里取 ——
        组级汇总会丢掉「是偶发还是稳定复现」这个信息，而决策层判断严重程度时
        正需要它。
        """
        return tuple(self._tracker.completed)

    @property
    def engine(self) -> RuleEngine:
        """本动作使用的规则引擎。

        适配器需要用它与 :attr:`windows` 配对产出逐次错误。**必须是同一个实例** ——
        换一个引擎重新求值会得到与组级汇总不一致的结果，而那种不一致不会报错。
        """
        return self._engine


def _calibration_offsets(
    definition: ActionDefinition, calibration: Calibration
) -> dict[str, float]:
    """把动作定义声明的基线偏移解析成具体数值。

    ``threshold_offsets`` 的值形如 ``("trunk_lean", 1.0)`` 时表示
    「阈值 + 该用户的站立躯干倾角」；直接给 ``float`` 则原样作为偏移。
    """
    resolved: dict[str, float] = {}
    for key, offset in definition.threshold_offsets.items():
        if isinstance(offset, tuple):
            name, scale = offset
            if name not in BASELINE_KEYS:
                raise ValueError(f"未知的基线量：{name}")
            value = getattr(calibration, name)
            if value is None:
                # 基线是**随动作而变**地采集的，所以「引用了别人采的量」是一种
                # 真实可犯的错（开合跳引用 ``heel_rise_ratio`` 就会走到这里）。
                # 不显式拦的话，``float(None)`` 抛的是
                # ``TypeError: float() argument must be a string or a number,
                # not 'NoneType'`` —— 指的是一行与病因毫无关系的代码。
                raise ValueError(f"校准结果缺少基线量：{name}（这个动作没有采集它）")
            resolved[key] = float(value) * float(scale)
        else:
            resolved[key] = float(offset)  # type: ignore[arg-type]
    return resolved


__all__ = [
    "BASELINE_KEYS",
    "ActionDefinition",
    "ActionRunner",
    "BaselineAdjustedThresholds",
    "Calibration",
    "Calibrator",
    "DEFAULT_REQUIRED_BASELINES",
    "RepTracker",
    "TrackingConfig",
]
