# 跨语言一致性测试向量（golden fixtures）

## 这是什么

本项目有**两份实现，每隔一层就有一次跨语言交接**，每次交接都靠这里的一份向量锁住：

| 交接 | Python（参考实现） | Dart（端侧运行时） | 向量 |
|---|---|---|---|
| 特征层 | `domain/src/vitalteen_domain/` | `app/lib/domain/` | `feature_conformance.json` |
| 决策请求 | `server/app/adapter.py` | `app/lib/app/decision_request.dart` | `decision_request_conformance.json` |
| 决策响应 | `server/app/service.py` | `app/lib/app/decision_response.dart`<br>`app/lib/app/local_decision.dart` | `decision_response_conformance.json` |

方向都是「Dart 必须与 Python 一致」，只是第三份一致的含义有两个：

1. 端侧**读得懂**服务端产出的响应（`decision_response_conformance_test.dart`）；
2. 端侧能拿同一份请求**算出**逐字段相同的响应（`local_decision_conformance_test.dart`）。

第 2 条是「连不上服务器时在手机上出一份报告」的成立条件：报告是同一份，
测试者报回来的结论才可能和联网时比较。共同点是：**都由服务端生成，端侧只读**。

## 为什么必须做这件事

如果训练期和推理期的特征分布存在细微差异，模型会**静默失效**：

- 训练时学到的是 A 分布，推理时见到的是 B 分布
- 准确率崩塌，但**不会报错**、不会有异常、日志里什么都看不到
- 你会以为模型不行，去调模型、调数据、调超参 —— 而根因在特征层

这是本项目最隐蔽也最昂贵的一类 bug。用一套共享的测试向量把它挡在门外，代价极低。

## `feature_conformance.json`

由 `domain/tools/build_fixtures.py` 生成。包含若干场景，每个场景给出：

- 一帧姿态（33 个关键点 + 画幅 + 机位）
- 该帧下**全部 23 个特征**的期望值

### 格式

```jsonc
{
  "fixture_version": "1.0",
  "frame_width": 720,
  "frame_height": 1280,
  "feature_codes": ["body_line_angle", "elbow_angle_L", ...],
  "scenarios": [
    {
      "id": "squat_bottom_parallel",
      "description": "平行蹲最低点：大腿水平、膝角≈90。兼作倾角负零回归……",
      "camera_view": "sagittal",
      "mirrored": false,
      "occluded_landmark_visibility": null,
      "overrides": { "LEFT_HIP": [0.44, 0.70], ... },
      "expected": {
        "knee_angle_L": 90.0,
        "knee_valgus_L": null,          // 侧视机位下不可用 —— null 也是契约
        "trunk_lean": 90.0
      }
    }
  ]
}
```

### `null` 是契约的一部分，不是缺失

某个特征在特定机位/可见性下**无定义**时，期望值是 `null`。
两份实现都必须在同样的情况下输出 `null`。

- **不允许**一边输出 `null`、另一边填 `0`
- 一个编造出来的 `0` 度膝角会被规则引擎当成「膝盖完全对折」，比缺失危险得多

这正是 `docs/domain-layer-design.md` §0 铁律二的强制方式。

### 浮点容差

fixture 保留 6 位小数。跨语言重实现无法做到逐位相同，比对用**绝对容差 `1e-4`**。
目标不是苛求位级一致，而是抓住「差了一个量级」「符号反了」「该是 null 却填了数」这类真错误。

## 场景清单与各守卫什么

| id | 防的回归 |
|---|---|
| `standing_sagittal` | 基准：膝角≈180、躯干倾角≈0 |
| `squat_bottom_parallel` | 平行蹲大腿水平。**倾角负零回归** —— 修复前 `thigh_tilt` 会返回 `-0.0` |
| `squat_bottom_parallel_facing_left` | 同上但人朝左。**锁定 atan2 象限行为** —— 修复前纯左向向量返回 `-180.0`，落在文档声明的 `(-180, 180]` 之外 |
| `squat_bottom_shallow` | 浅蹲，与平行蹲构成对照，供深度规则测试使用 |
| `standing_asymmetric_knee` | **左右侧特征不得串用关键点** —— 若左右腿误用同一组点，左膝角会跟着变 |
| `standing_frontal_valgus` | 正视机位：额状面特征可用、侧视特征必须判机位不匹配 |
| `standing_oblique45` | 斜前机位：机位集合的边界行为 |
| `standing_occluded_knee` | 关键点遮挡 → 特征必须 `null` 且标注 `low_visibility` |

## `decision_request_conformance.json`

由 `server/tools/build_request_fixture.py` 生成。它锁定的是**端侧发出去的请求**
与服务端适配器产出的是否同一个东西 —— 上面那份锁的是「特征值」，这份锁的是
「字段名、序号基准、单位、哪些该是 null」。

### 为什么它跑的是整条链路，而不是直接比对 JSON

端侧拿不到「已经调好个体化偏移的引擎」：`ActionRunner` 刻意不接 `config` /
偏移参数，它自己从标定算。所以两侧都只能走
**「标定 → 建 runner → 喂帧 → finishSet → 组装」**这条真实路径，fixture 里
存的因此是**原始姿态**而不是特征值。

代价是这条测试同时依赖状态机、相位切分、特征计算在两侧一致。那正是收益：
它们都在真实链路上，不在旁路上。任何一处漂移都会让逐次时长、相位时长或
错误判定对不上。

### 格式

```jsonc
{
  "camera_view": "oblique45",     // 与产品一致，不是测试用的侧视
  "base_pose": { "NOSE": [x, y], ... },   // 完整 33 点基准
  "frames": [ { "timestamp_ms": 1000, "overrides": { "LEFT_KNEE": [x, y] } } ],
  "calibration_frames": 20,
  "thresholds": { "version": "...", "action_code": "SQUAT", "values": { ... } },
  "context": { "sex": "female", "age": 16, "grade": "高一", "standard_group": "高中女子" },
  "pose_quality": { "mean_visibility": 0.94, ... },
  "expected_request": { "request_id": ..., "set": {...}, "reps": [...], ... }
}
```

场景里**两次深蹲的深度刻意不同**：第一次蹲到位，第二次明显不够。
这样 `fault_stats` 里既有「有错误的 rep」也有「没错误的 rep」，
「只有第二次」这个断言才验得出**序号基准**（0-based 还是 1-based）——
那是这条接缝上最容易错、也最不容易被发现的一处。

### 闸门测试先于一致性测试

Dart 侧那条测试里有一半是**先验场景**：若几何或分段参数变化让两次深蹲都数不出来，
逐字段比对会以「空数组等于空数组」的形式全绿通过。那是最糟的一种绿。

## `decision_response_conformance.json`

由 `server/tools/build_response_fixture.py` 生成，锁的是端侧那份**手写**的响应模型
（`app/lib/app/decision_response.dart`），以及端侧那份**手写**的本机判定器
（`app/lib/app/local_decision.dart`）。手写就得有东西锁住：服务端把一个必填字段
改名，端侧会一路解析到运行时才炸 —— 而那时用户已经做完一组动作了。

### 场景清单

| name | status | 覆盖的分支 |
|---|---|---|
| `ok` | ok | 有候选错误。**请求来自请求 fixture 的同一条真实流水线**，所以 `deviations` 是领域层真算出来的 |
| `clean` | ok | 一个候选都没触发。这是**有效结论**，不是数据缺失 |
| `abstain` | abstain | 质量门第一条：可见性压到 0.2（门限 0.5） |
| `abstain_low_coverage` | abstain | 质量门第二条：有效帧占比 0.55（门限 0.6）。与上一条给出**不同的弃权理由**，而那段理由是直接显示给用户的原文 |
| `abstain_no_reps` | abstain | 质量门第三条，兼钉住门的**顺序**：先判质量再判有没有候选。写反了会把「没测到」渲染成「测得好，100 分」 |
| `primary_by_count` | ok | 主问题取**候选集内出现次数最多**者，不是 `candidates[0]` |
| `primary_tie_first_stat` | ok | 并列时取 `fault_stats` 的**首个**极大元素（Python `max` 的语义）。两个码都命中 2 次，而统计顺序与候选序**故意相反** |
| `severity_unknown_vs_zero` | ok | **未知与零不是一回事**：一条 `severity_0_1 == 0.0` 的偏离（真零 → 0 分），一条没有任何偏离明细（未知 → 退回出现率 50 分） |
| `severity_rounding` | ok | 半偶舍入：`0.125` / `0.375` 是二进制精确值，×100 后正好落在 `.5` 上。Python 给 12 / 38，Dart 原生 `round` 会给 13。可见性同时取 `0.90625`，钉住 `round(x, 4)` 的 0.9062 |
| `stats_disjoint` | ok | `fault_stats` 与 `candidates` 完全不相交 → 主问题退回候选集首项以保证契约成立，证据**如实为空**而不是编一个 |
| `no_reps_thin` | ok | `reps` 为空但组级统计在 → 严重度退回**出现率**，不当成零 |
| `plans_equipment` | ok | 器材过滤 + 覆盖数优先：带 `available_equipment: ["弹力带"]`，覆盖 2 个码的方案排在覆盖 1 个码的前面 |
| `plans_age_filter` | ok | 年龄压到 11 → 一条方案都选不出。锁住「有错误但没有建议」这个组合：`choice` 为 null 而 faults 非空 |

`ok` / `clean` / `abstain` 三条对应端侧报告里**三条完全分开的渲染路径**；其余场景
逐一压住判定器里的一个分支。**漏掉一个分支，那句文案就没人锁** —— 文案字符串仍然是
两份（弃权三句、`dose_note`、`selection_reason`、模板 ID 的拼法）。

### 请求是合成的，但这不影响它是证据

只有前三个场景的请求来自真实流水线。其余在**契约层** `model_copy` 合成 ——
因为要压的那些分支（严重度恰好 0.125、统计与候选集不相交）领域层根本产不出来。
这不削弱这条锁：决策层只读请求，而**请求形状本身的真伪由
`decision_request_conformance.json` 负责**。合成的是输入，`expected_response`
永远是服务端跑出来的。

每个场景的 `note` 字段里写明了它是合成的还是真实流水线产出的。

### `stats_disjoint` 的文案渲染不出来，这是设计

它给不出 `primary_count`（组级统计里没有那个码），而端侧的规矩是**不硬填** ——
填 0 就是编一个「一次都没出现」的事实。整句作废、改用
`fallback_template_id`，这是 `app/lib/app/message_catalog.dart` 顶上的既定决定。
端侧测试把这条列进一份**显式名单**，名单一旦变长就说明又多了一种「服务端只能
给出半句话」的情形。

### 请求为什么也放进来

端侧报告要显示「第 2 次出现了什么问题」，而响应里只有 `evidence.reps`（序号）
与一条**恒为 `null`** 的 `evidence.metric` —— 具体偏离多少度，得回请求里按错误码
join。把 `request` 一并放进 fixture，端侧那条 join 才有东西可测。

### 只有规则兜底路径（`decided_with: "rule-only"`）

模型路径要一个能返回固定答案的假模型，而假模型一旦进了 fixture，
「这是服务端的真实输出」就不再是证据。模型路径由 `server/tests/test_service.py`
的鸭子类型桩覆盖。`abstain` 与 `clean` 两条路径本来就不调用模型，所以它俩不受此限。

端侧的本机判定**永远走规则路径**，`meta.decision_model_version` 老实写 `rule-only`。

### 唯一允许的差异：`meta.latency_ms`

服务端那条路测的是真实耗时（fixture 生成时已归零），本机路径没有网络往返可测，
恒为 0。除此之外**任何一个字段不同都算不一致** —— 包括文案字符串、模板 ID 的拼法、
`gates` 的值、列表的顺序。

## 如何重新生成

```bash
cd domain
PYTHONPATH=src python -m tools.build_fixtures          # 重新生成
PYTHONPATH=src python -m tools.build_fixtures --check  # 只校验是否同步（CI 用）

cd server
PYTHONPATH=.:../domain/src python -m tools.build_request_fixture
PYTHONPATH=.:../domain/src python -m tools.build_response_fixture
PYTHONPATH=.:../domain/src python -m tools.build_request_fixture --check
PYTHONPATH=.:../domain/src python -m tools.build_response_fixture --check
```

（从仓库根跑 `python scripts/check_all.py` 会把这几条 `--check` 一起执行。）

**改动一侧实现后，如果 `--check` 失败，先判断这是有意的行为变更还是 bug。**

- 有意的行为变更 → 重新生成，并在提交信息里说明变化原因
- 意外漂移 → 是 bug，改回去

场景定义的**物理合理性由人工审阅** `build_fixtures.py` 里的 `SCENARIOS` 表保证 ——
那是可读的 Python，不是让人去改 JSON。每个场景的 `description` 要写清楚它在防什么，
将来有人改动实现时才能判断能否安全接受 fixture 变化。

## Dart 端怎么用

在 `app/test/` 下写一个参数化测试，逐个加载同样的 `feature_conformance.json`：

1. 按场景的 `overrides` / `mirrored` / `occluded_landmark_visibility` 重建 `PoseFrame`
2. 用同样的 `camera_view` 跑 Dart 版特征提取
3. 逐特征比对：期望 `null` 则必须 `null`，否则 `abs(实际 - 期望) <= 1e-4`

**注意**：Dart 侧不要 import Python 的构造逻辑，也不要复用同一份辅助代码 ——
独立重建姿态，"场景重建"本身也应当是被验证的一环。
