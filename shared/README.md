# shared/ · 跨语言共享资产

这个目录**不属于任何一个模块**。它是模块之间、以及两种语言实现之间的**真源**。

放在这里的东西有一个共同特征：**一旦两侧不一致，出错方式是静默的** ——
没有报错、没有红色测试，只是结果悄悄地不对。

```
shared/
├── fixtures/     跨语言一致性测试向量（特征 × 10 场景、决策请求、决策响应）
├── contracts/    决策接口的 JSON Schema（从服务端 Pydantic 定义导出）
├── thresholds/   体育阈值表（74 条，当前全部待核定）
├── plans/        矫正方案库（12 条，当前全部待核定）—— 决策响应里的 plan_id 靠它变正文
├── messages/     面向青少年的文案模板 —— 决策响应里的 template_id 靠它变正文
└── decision/     规则兜底路径的工程参数 —— 断网时端侧就靠这一份在本机算出同一份结论
```

后四个目录都是 **App 运行时真的会读**的东西，因此都会被打进安装包
（`fixtures/` 与 `contracts/` 不会，它们是开发期资产）。四个目录里**只放数据文件**，
说明文档就是本文 —— 每个目录各写一份 README 会让同步流程的说明散成四份，
而它们说的其实是同一件事。

---

## 一、为什么这些东西必须共享

`domain/`（Python）与 `app/lib/domain/`（Dart）是**两份独立的实现**。它们算出的特征
若不一致，模型会静默失效 —— 这是本项目最隐蔽也最致命的一类 bug：没有报错，
只是准确率悄悄崩塌。

所以 `fixtures/` 里的 golden 测试向量是**唯一的裁判**：
**任何特征算子的改动，必须同时更新 fixtures，并让两种语言的测试同时通过。**

同理，`thresholds/` 必须被端侧与服务端**用同一份数值**读取。端侧算判定、服务端出决策，
两边阈值差一点点，结论就会对不上 —— 而且不会报错。

---

## 二、thresholds/：带来源与版本号的体育阈值

阈值分两类，性质完全不同：

| 类别 | 存放位置 | 谁有权改 | 能否驱动扣分 |
|---|---|---|---|
| **体育阈值**（关节角合格线、错误严重度切分） | 本目录 | **仅体育专业成员核定** | 仅 `source_type != pending_review` 者 |
| **工程默认值**（滤波窗口、投票帧数、可见性门控） | 各模块 `config` | 工程师 | 不参与 |

**工程师不得在代码里硬编码任何体育阈值。** 这不是洁癖 —— 混进来的第一个硬编码数字
会被下一个维护者当成「国标规定」，然后写进答辩材料。

每条阈值带 `source_type`：

- `national_standard` —— 《国家学生体质健康标准》及配套测试方法
- `literature` —— 运动科学文献
- `pending_review` —— **尚无可靠来源，只能驱动提示，不得驱动扣分**

**当前表里 74 条全部是 `pending_review`。** 这不是遗漏，而是诚实的状态：公开来源里
不存在面向中国学生群体的权威切点。系统现在能跑、能出提示，但**不能扣分**。

这条治理在两侧都有落点，而且是**会撞墙的实现**，不是文档里的君子协定 ——
Python 是 `ThresholdTable.require_scorable()`，Dart 是 `ThresholdTable.requireScorable()`：
试图用未核定的阈值扣分，会在那里抛异常，而不是等到用户看见一个来源不明的评价。

### 改阈值表时要做什么

1. 改 `shared/thresholds/`（**这是真源**）
2. 跑 `python scripts/sync_assets.py` 把它同步到 `app/assets/thresholds/`
3. 跑 `python scripts/check_all.py`

第 3 步里的「端侧 · 资产同步」会逐字节比对两份文件，不一致就红。
**不要手工编辑 `app/assets/thresholds/` 下的文件** —— 下次同步会直接覆盖它。

`plans/`、`messages/` 与 `decision/` 也走同一条链路，只是它们的上游不同：
`plans/` 与 `decision/` 的真源在服务端代码里（`server/app/plans.py`、
`server/app/service.py` 的 `DecisionSettings`），要先导出；`messages/` 的真源
就是那份 JSON 本身。

> **为什么需要同步这一步。** Flutter 的 assets 必须在包目录内（`app/assets/…`），
> 没法直接引用仓库另一处。于是就有了两份副本，而两份副本一旦漂移**不会报错**，
> 只会让同一个动作在手机上和服务端得出不同结论。所以同步必须是单向的、可校验的，
> 而不是靠人记得复制。

---

## 三、contracts/：决策接口的契约

两份 JSON Schema：`decision_request.schema.json` 与 `decision_response.schema.json`。

**它们不是手写的**，是从服务端的 Pydantic 定义（`server/app/contracts.py`）导出的：

```bash
cd server && python -m tools.export_schema            # 重新导出
cd server && python -m tools.export_schema --check    # 校验是否同步
```

端侧的模型**是手写的**（`app/lib/app/decision_request.dart` 与 `decision_response.dart`），
这是一处有意的偏离：生成解决的是「照 schema 抄错」，而这条接缝真正的风险是**两侧漂移**
（服务端改了字段端侧还在发旧的、端侧换了单位服务端没跟上），生成出来的模型对此一无所知。
完整理由与替代方案见 [app/README.md](../app/README.md) 的「契约模型是手写的」。

手写的代价用**跨语言 fixture** 补：`shared/fixtures/` 下的
`decision_request_conformance.json` 与 `decision_response_conformance.json` 都由
**服务端**生成，端侧必须能复现 / 解析它们。请求那份还能顺带覆盖 schema 里
「`candidates` 最多 20 项」这类约束 —— 漏了这条会一路发到服务端才 400，
而它背后的理由是 Laya 在选项数超过约 20 后准确率急剧下降。

契约里那些不显眼但重要的约束（版本字段必填、未知字段拒绝、候选集封闭、
弃权必须说明原因……）见 [server/README.md](../server/README.md)。

---

## 四、fixtures/：跨语言一致性的裁判

`feature_conformance.json`：10 个场景 × 全部 31 个特征，容差 1e-4。
格式与用法见 [fixtures/README.md](fixtures/README.md)。

其中三个场景是专门防回归的，**别删**：

- `squat_bottom_parallel` —— 负零（`atan2(-0.0, …)` 返回 `-π` 而不是 `+π`）
- `squat_bottom_parallel_facing_left` —— 象限
- `standing_asymmetric_knee` —— 左右不串用关键点

另外两份是**决策契约**两侧的锁，都由服务端生成、端侧只读：

| 文件 | 生成者 | 端侧要做什么 |
|---|---|---|
| `decision_request_conformance.json` | `server/tools/build_request_fixture.py` | 用同一批原始姿态**复现** `expected_request` 并逐字段比对 |
| `decision_response_conformance.json` | `server/tools/build_response_fixture.py` | （a）**解析** `expected_response` 并把字段落进报告；（b）拿同一份 `request` 在本机**算出**逐字段相同的响应 |

响应那份之所以有两个方向：端侧现在能在**连不上服务端时自己算一份报告**
（见 `app/lib/app/local_decision.dart`），而两份实现算出来必须是同一件事 ——
否则测试者报回来的结论没法与联网时比较，「为什么这次说膝内扣、上次说深度不足」
也无法解释。方向（a）要求读懂，方向（b）要求复现；13 个场景逐一压住判定器里
的一条分支，清单见 [fixtures/README.md](fixtures/README.md)。

响应那份只有**规则兜底路径**（`decided_with: "rule-only"`）。模型路径要一个能返回
固定答案的假模型，而假模型一旦进了 fixture，「服务端的真实输出」就不再是证据。
本机路径因此**永远不调用决策模型** —— `meta` 老实写 `rule-only`。

---

## 五、plans/：矫正方案库

`plan_library.json`，从 `server/app/plans.py` 导出：

```bash
cd server && python -m tools.export_plans            # 重新导出
cd server && python -m tools.export_plans --check    # 校验是否同步
```

**为什么它要在手机里。** 决策响应的 `choice.selected_plan_ids` 只给 ID —— 正文不进
响应，为的是让一次结论可复现、让文案能独立评审。于是「练什么、怎么练」这一段
只能由端侧按 ID 自己查。

**为什么 12 条全导，包括 `draft`。** 方案库的检索在「没有已核定方案」时会退回未核定
方案并把这件事写进 `dose_note`（`PlanLibrary.for_faults_with_review_fallback`）。
种子库现在全部是 draft —— 只导 active 的话，端侧查不到响应里给的任何一个 ID。

**剂量导出的是渲染结果（`dosage_text`），不是三个数字。** 那几个数字都可能是
`None`，含义是「尚未核定」而不是「不需要」。让端侧再实现一遍 `Dosage.describe()`
就是再造一处会漂移的地方。

包里的这份可能**落后于服务端**（改了方案但没重新导出，`--check` 会在下次跑
`check_all.py` 时红）。端侧遇到查不到的 `plan_id` 时显示
「这条建议不在本应用的方案库中」，**不静默丢块**。

---

## 六、messages/：面向青少年的文案模板

`teen_v1.json`。这份**没有上游生成器** —— 真源就是它自己，所以 `check_all.py` 里
只有「资产同步」一项，没有对应的 `tools/export_*.py`。

服务端不生成自由文本：`DecisionResponse.message` 只回 `template_id` 加 `params`，
正文由端侧按 ID 在这里查。这条设计的目的是让**学生看到的每一句话都经过人工写好的**，
而不是模型现场编的。

| 占位符 | 来源 | 一定会有吗 |
|---|---|---|
| `{total}` / `{valid}` | 本组总次数 / 有效次数 | 是 |
| `{primary}` | 主问题的中文名 | 否 |
| `{primary_count}` | 主问题出现的次数 | 否 |

**端侧不会硬填缺失的占位符**：模板用到的键只要有一个在 `params` 里找不到，
整句作废，改用 `fallback_template_id`。宁可少说一句，也不要在句子里留下一个
空格（「它在 次里出现过」）或者替服务端猜一个数。

表里只覆盖**深蹲实际能产出的**那 6 个 ID 加一条兜底。`server/app/taxonomy.py` 里有
45 个码，但不要照着写满：那些码对应的动作还没实现，写出来的模板永远渲染不到，
却要跟着每次文案评审一起过一遍。`server/tests/test_messages.py` 双向查这件事
（有码无模板、有模板无码都会红）。

---

## 七、decision/：规则兜底路径的工程参数

`rule_settings.json`，从 `server/app/service.py` 的 `DecisionSettings` 导出：

```bash
cd server && python -m tools.export_rule_settings            # 重新导出
cd server && python -m tools.export_rule_settings --check    # 校验是否同步
```

**为什么它要在手机里。** 连不上决策服务时，端侧用 `local_decision.dart` 在本机
算一份报告（见 `app/README.md`）。要算出**同一份**，它得知道服务端当时用的那几个
数：质量门的两条下限、方案条数上限、严重度档位的切点、评分权重与评级阶梯。

**为什么它不在 `thresholds/`。** 那两个目录的治理语义完全不同：

| | `thresholds/` | `decision/` |
|---|---|---|
| 是什么 | **体育阈值**（关节角合格线、严重度切分） | **工程参数**（门限、权重、截断条数） |
| 谁有权改 | **仅体育专业成员核定** | 工程师 |
| 能否驱动扣分 | 仅 `source_type != pending_review` 者 | 不参与扣分 |

`service.py` 里那段注释已经写明这些是工程参数。把它们混进 `thresholds/` 会让两侧的
`source_type` 治理一起失效 —— 一张「部分条目工程师可以随便改」的阈值表，
等于给下一个人开了口子。端侧 `ThresholdTable.fromJson` 还按 `thresholds[]` 逐条解析，
多出无关键要么被静默忽略、要么直接炸：凭空多一种静默失败。

**这份锁的是数值常量；行为与文案由 `fixtures/` 里那份响应 fixture 锁。**
两把锁都要，缺一不可：参数一致而算法不一致，结果照样对不上。
