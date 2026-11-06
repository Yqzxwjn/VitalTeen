"""动作定义层。

每个动作 = 一组转移（状态图）+ 一组错误规则 + 一个相位映射，全部封装在
:class:`~vitalteen_domain.exercises.base.ActionDefinition` 里。新增动作不需要
改动状态机、特征层或规则引擎（设计文档 §4.1 的注册表模式）。

当前已实现：

- :mod:`~vitalteen_domain.exercises.squat` —— 深蹲（45° 斜机位主链路）
- :mod:`~vitalteen_domain.exercises.slj` —— 立定跳远（同样 45° 斜机位）
- :mod:`~vitalteen_domain.exercises.jj` —— 开合跳（**唯一一个正面机位**的动作）
- :mod:`~vitalteen_domain.exercises.pu` —— 俯卧撑（回到 45° 斜机位主链路）
- :mod:`~vitalteen_domain.exercises.situp` —— 仰卧起坐（同样 45° 斜机位，
  第一个**躺着做**的动作）
- :mod:`~vitalteen_domain.exercises.rope` —— 跳绳（同样 45° 斜机位，
  唯一一个**整个人周期性离地**的动作）
- :mod:`~vitalteen_domain.exercises.pullup` —— 引体向上（同样 45° 斜机位，
  第一个**极端状态在最高点**的动作）
- :mod:`~vitalteen_domain.exercises.plank` —— 平板支撑（同样 45° 斜机位，
  第一个**计时制**的动作）
- :mod:`~vitalteen_domain.exercises.sit_reach` —— 坐位体前屈（同样 45° 斜机位，
  第一个**动作本身带有「保持」段**的动作）

它们都以「非国标训练项目、纯姿态可完整判定」为前提选出 —— 国标正式测量项里能做
成绩测量的只有仰卧起坐、引体向上、跳绳，其余见设计文档附录 A 的能力边界表。

开合跳是第一个正面机位的动作，它顺带解决了两处「把深蹲要什么当成所有人都要什么」
的共享组件缺陷：标定要求的基线量、站位门禁的必需关键点，两处都改成了随动作而变
（见 ``ActionSpec.calibrationBaselines`` / ``ActionSpec.requiredLandmarks``）。

俯卧撑带来了第二处同类改动：它要在**矢状面上把两种方向相反的错分开**
（塌腰 vs 撅臀），而现成的 ``body_line_angle`` 是个 0–180° 的夹角，两者在它上面
完全同形。所以特征层多了一个带符号的 ``body_line_offset_ratio`` —— 符号取的是
重力方向而不是「连线的哪一侧」，理由见 ``features.py`` 里那条算式的注释。

仰卧起坐是第一个**躺着做**的动作，它带来的是第三处：
``shoulder_height_ratio``（肩比踝高多少，以躯干长归一）。
量「上身起来了多少」必须拿一个跟着人走的参照物 —— 单目下画面里的上下位移
一半来自人自己的移动，而踝在整组里贴在垫上不动，是唯一稳定的零点。

跳绳带来的是第四处，而且方向与前三处**相反**：它是唯一一个拿**画面**当零点的
动作（``foot_height_ratio`` 量的是脚尖高出画面下缘多少）。前三处都在说
「别拿画面当参照」，这里能拿，是因为跳绳有一条别的前提 —— **手机架稳不动**，
于是画面下缘在一整组里是个固定不动的水平面，而「离地」要的正是相对地面的量。
它还带来一串时序上的新东西：一次跳跃只有十几帧，所以防抖参数第一次被调到
引擎允许的最小值（见 ``rope.py`` 的 ``build_rope``）。

引体向上带来的是第五处，它是 ``Phase`` 表第一次为了一个动作**新增成员**而不是
复用：它就是俯卧撑那个状态环的**上下颠倒版**（悬垂 → 拉起 → 顶部 → 下放），
但「身体的极端」在最高处，而 ``Phase.BOTTOM`` 的名字与它上面那三条规则的文档
说的都是「最低点」。所以有了 ``Phase.APEX``。它同时带来第二处与机位无关的
新东西：``mouth_wrist_dy``（嘴比手腕高多少，以躯干长归一）—— 双手握在杠上，
腕的高度就是杠的高度，于是「下颌过杠」第一次有了一个**几何上精确**的量，
而不是靠推算。它还是没有拿这个量做计数门槛（理由见 ``pullup.py``）。

平板支撑带来的是第六处，而这一次动的**不是特征层，是产品形态**：它是第一个
rep 不等于「一次动作」而是**一段时间**的动作（两态环 ``HOLD_BREAK ⇄ HOLD_OK``，
开窗到封存之间就是那一段支撑）。所以它一个特征都不用加 —— 判它要的两个量
（``trunk_lean`` 判身体放平没有、``body_line_offset_ratio`` 判体线直不直）
都是现成的，撑地的第三条判据用的还是俯卧撑那个肘角。

**它的两态环还回答了一个此前没被问过的问题**：为什么跳绳需要第三个状态、
而这里不需要。跳绳的规则要判的证据（落地缓冲）发生在「回到 resting_state」**之后**，
两态环下那一段整个落在窗口外；平板支撑要判的东西全程都在支撑段里，窗口正好圈住。

它同时是第一个**能把边界写成一句人话**的动作：趴在地上摆出同样的关节构型，
在单目投影下与真正的平板支撑完全同形（差别只有离地多高）。这条写进了
``plank.py`` 的模块文档，也是本仓库第一条「不是暂时没做、而是这个机位下
不可能做」之外、由乘积式判据**主动**换来的边界。

坐位体前屈带来的是第七处，而且这一次动的**不是特征层，是规则引擎**：
「弹振借力」这个错的存在形式不是某一帧上的某个数值偏了多少，而是**整段序列的
形状** —— 靠来回弹够距离的人，前伸到底的那个角度与慢慢伸的人可以一模一样
（弹的那一下甚至更远）。现成的四种归约（``MIN`` / ``MAX`` / ``MEDIAN`` /
``ANY_FRAME``）都只看得见一个点，于是加了第五个 ``Reduce.REVERSALS``
（窗口内相邻帧差分的符号翻转次数，带死区）。这是本仓库第一次因为一个**错误
的形态**而不是一个**量的缺失**去扩引擎。

它同时是第一个**动作自带「保持」段**的动作：国标要求前伸到底后停两秒，而
端侧不数那两秒，而是把「伸到底」当成一个独立状态（``HOLDING``）。停多久不
影响计数，只影响这个状态停留多少帧 —— 而规则看的是这段里发生了什么。

**关于 ``ACTION_CODE`` 这个名字。** 本模块曾把深蹲的 ``ACTION_CODE`` 裸导出，
于是它成了一个「默认动作」的隐式别名。加了第二个动作之后，裸导出同名常量会让
``from vitalteen_domain.exercises import ACTION_CODE`` 悄悄拿到深蹲那一个 ——
调用方无从知道自己在用谁的定义。所以这里把它固定成 ``SQUAT_ACTION_CODE`` /
``SLJ_ACTION_CODE`` 这样**带动作前缀**的名字。深蹲那个的旧名字**不保留别名**：
留着就等于把这个坑继续留着，而这正是要消掉的东西。
(``exercises/squat.py`` 模块内部的 ``ACTION_CODE`` 不变，它在那里是明确的。)
"""

from __future__ import annotations

from .base import (
    BASELINE_KEYS,
    DEFAULT_REQUIRED_BASELINES,
    ActionDefinition,
    ActionRunner,
    BaselineAdjustedThresholds,
    Calibration,
    Calibrator,
    RepTracker,
    TrackingConfig,
)
from .jj import (
    JJ_STATES,
    build_jj,
)
from .jj import (
    ACTION_CODE as JJ_ACTION_CODE,
)
from .plank import (
    PLANK_STATES,
    build_plank,
)
from .plank import (
    ACTION_CODE as PLANK_ACTION_CODE,
)
from .slj import (
    SLJ_STATES,
    build_slj,
)
from .slj import (
    ACTION_CODE as SLJ_ACTION_CODE,
)
from .pullup import (
    PULLUP_STATES,
    build_pullup,
)
from .pullup import (
    ACTION_CODE as PULLUP_ACTION_CODE,
)
from .pu import (
    PU_STATES,
    build_pu,
)
from .pu import (
    ACTION_CODE as PU_ACTION_CODE,
)
from .rope import (
    ROPE_STATES,
    build_rope,
)
from .rope import (
    ACTION_CODE as ROPE_ACTION_CODE,
)
from .sit_reach import (
    SRT_STATES,
    build_srt,
)
from .sit_reach import (
    ACTION_CODE as SRT_ACTION_CODE,
)
from .situp import (
    SU_STATES,
    build_su,
)
from .situp import (
    ACTION_CODE as SU_ACTION_CODE,
)
from .squat import (
    SQUAT_STATES,
    build_squat,
)
from .squat import (
    ACTION_CODE as SQUAT_ACTION_CODE,
)

__all__ = [
    "BASELINE_KEYS",
    "JJ_ACTION_CODE",
    "JJ_STATES",
    "PLANK_ACTION_CODE",
    "PLANK_STATES",
    "PULLUP_ACTION_CODE",
    "PULLUP_STATES",
    "PU_ACTION_CODE",
    "PU_STATES",
    "ROPE_ACTION_CODE",
    "ROPE_STATES",
    "SLJ_ACTION_CODE",
    "SLJ_STATES",
    "SRT_ACTION_CODE",
    "SRT_STATES",
    "SQUAT_ACTION_CODE",
    "SQUAT_STATES",
    "SU_ACTION_CODE",
    "SU_STATES",
    "ActionDefinition",
    "ActionRunner",
    "BaselineAdjustedThresholds",
    "Calibration",
    "DEFAULT_REQUIRED_BASELINES",
    "Calibrator",
    "RepTracker",
    "TrackingConfig",
    "build_jj",
    "build_plank",
    "build_pullup",
    "build_pu",
    "build_rope",
    "build_srt",
    "build_su",
    "build_slj",
    "build_squat",
]
