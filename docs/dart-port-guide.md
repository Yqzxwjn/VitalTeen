# 端侧实现指南（Dart）

> 面向：负责 `app/` 的同学
> 前置：Flutter 工具链就绪（见 [phase0-environment.md](phase0-environment.md)）

端侧要做三件事：**取帧**、**算特征**、**判动作**。第三件在 Phase 1 只做深蹲。

本文档不重复设计文档的内容，只讲**怎么落地**，以及**哪些地方看起来能省事、实际会出事**。

---

## 零、先把工程建起来

Flutter SDK 就绪后，第一件事是建工程：

```bash
cd D:/Code/VitalTeen
flutter create --project-name vitalteen_app --platforms android app
```

**⚠️ `flutter create` 会生成它自己的 `app/README.md`，覆盖掉仓库里那份** ——
那份里写着技术选型、验收标准、以及指向本文档的指引。跑之前先备份：

```bash
cp app/README.md /tmp/app-readme-backup.md
flutter create --project-name vitalteen_app --platforms android app
cp /tmp/app-readme-backup.md app/README.md
```

两个参数值得说一句：

- `--platforms android` —— **iOS 出包必须有 Mac**（见开发计划的风险表），当前环境没有，
  所以 iOS 排在非关键路径。将来需要时补一条命令即可：
  `cd app && flutter create --platforms ios .`
- `--project-name vitalteen_app` —— Dart 包名必须是合法的标识符，目录名 `app` 也合法，
  但显式指定更清楚。`--org` 决定 Android 的 applicationId，按团队域名填。

建完先别写业务代码 —— 下一步是验证工具链，不是写功能。

## 一、先做什么

```
第 1 步  真机帧率验证：33 点能不能实时出、推理够不够 15 FPS   ✅ 已完成（19 fps）
第 2 步  把 domain/ 的特征层移植成 Dart，通过 golden fixtures   ✅ 已完成
第 3 步  接状态机、移植动作定义，跑通「计数 + 相位」            ✅ 已完成（九个动作）
第 4 步  接 UI：骨架叠加、实时角标、机位自检提示                ✅ 已完成
第 5 步  接决策服务：组装 DecisionRequest，POST 到笔记本        ✅ 已完成

五步都走完了。这份指南保留下来是因为**第三节那十几条坑** —— 它们是这一路上
真正花掉时间的东西，而每一条的病因都不在报错信息里。后续再加动作、再动
`platform/` 层时，先读那一节。

第 1 步**没有跑官方 example，而是自己写了一个探针**（`app/lib/phase0/fps_probe.dart`）。
官方 example 的价值是「它一定是对的，所以失败一定是环境问题」；但它要另外
clone、另外配依赖，而我们的工程里 `google_mlkit_pose_detection` 与 `camera`
本来就装着。更重要的是，探针跑通之后就是相机页的骨架，不是一次性代码。
用它验证的是**我们这套版本组合**的帧率 —— 那才是真正要回答的问题。
```

**第 2 步是分水岭。** 特征层不过 fixtures，后面全是白做 —— 因为模型训练用的是
Python 算出的特征，端侧算出另一套，准确率会静默崩塌且没有任何报错。

---

## 二、逐个模块的对照

**下表已全部落地**（`app/lib/domain/`），另有一层 ML Kit 适配在 `app/lib/platform/`。
对照表留着是有用的：将来有人改其中一侧时，得知道另一侧在哪。

| Python（参考实现） | 你要写的 Dart | 注意 |
|---|---|---|
| `domain/src/vitalteen_domain/landmarks.py` | 常量与索引 | 直接照抄，33 个索引不能错一个 |
| `geometry.py` | 几何算子 | **看第三节第 1 条** |
| `pose.py` | 姿态帧对象 | 见第三节第 2 条，这是最值得投入设计的地方 |
| `filters.py` | 中值 + One Euro | 纯数值，逐行翻译即可 |
| `features.py` | 31 个特征提取 | 逐个对照 `FEATURE_SPECS`，机位依赖不能漏 |
| `state_machine.py` | 通用状态机 | 三条防抖机制一个都不能少，见第三节第 4 条 |
| `exercises/*.py` | 动作定义（深蹲/立定跳远/开合跳/俯卧撑/仰卧起坐/跳绳/引体向上/平板支撑/坐位体前屈） | 状态图与守卫条件**逐字对齐**，每个动作两侧数值必须逐位相同 |
| `rules.py` | 规则引擎 | 五种归约**都要**（`ANY_FRAME`/`MIN`/`MAX`/`MEDIAN`/`REVERSALS`）。深蹲只用到前两种，但少实现一种，后续动作就无处落脚；剩下的三种各有各的来路（见 `rules.dart` 里每个成员的注释）|

---

## 三、这一路上踩过的坑（按危害排序）

### 1. 坐标还原：归一化坐标必须先乘回像素坐标

**这是本项目最容易犯、后果最严重、而且不会报错的错误。**

ML Kit 给的 `x, y` 是归一化坐标（0–1，分别按图宽、图高折算）。直接拿它算角度，
会被画幅宽高比扭曲 —— 一个 720×1280 竖屏上真实 90° 的角，用归一化坐标算出来是
**120°**。

参考实现的做法是**让这个错误写不出来**：`PoseFrame.pixel()` 是拿到像素坐标的
唯一入口，几何算子只接受像素坐标。Dart 侧建议照做 —— 不用 `(double, double)`
裸元组，而是定义一个 `PixelPoint` 类型，让类型系统替你记住这个约定。

### 2. 「不可用」必须是 `null`，不能填 0

`features.py` 里每个特征都带 `valid` 与 `invalid_reason`。三种不可用情形：
`low_visibility`、`view_mismatch`、`degenerate`。**必须在 Dart 侧同样返回 `null`。**

一个编造出来的 0 度膝角会被规则引擎当成「膝盖完全对折」，比缺失危险得多。
Dart 用 `double?` 表达，不要在计算链上写 `?? 0`。

### 3. 负零陷阱：`atan2(-0.0, -100)` 返回 `-π` 而不是 `+π`

倾角函数里，**负零的符号会参与象限判定**。纯水平向左的向量会得到 `-180.0`，
落在文档声明的 `(-180, 180]` 之外；水平向右会得到 `-0.0`。

这本身不影响角度大小，但会让**跨语言比对出现假不等** —— 而 fixtures 是逐值比对的。

Dart 的 `atan2` 行为与 Python 一致（都遵循 IEEE 754），所以你需要**照抄
`_normalize_signed_degrees` 这一段**：结果 `<= -180` 时加 360，其余情况加 `0.0`
（`-0.0 + 0.0 == +0.0`，这一步同时消掉负零）。

### 4. 状态机必须带回退边

只写「一路向前」的链条（`STANDING→DESCENT→BOTTOM→ASCENT→STANDING`）时，
用户没沿预期路径走就会**卡死在中间状态** —— 弯 20° 又直起来、起身到一半又蹲下去，
都会让状态机再也数不出任何动作。

深蹲定义里有两条回退边（`DESCENT→STANDING` 假动作、`ASCENT→DESCENT` 回蹲），
**不是可选的健壮性增强，而是正确性的一部分**。

### 5. 深度判定用「极值归约」，不是「越界帧计数」

规则引擎有两种归约方式（`Reduce` 枚举），用错会让**每一个动作都被误判**：

- `ANY_FRAME`：越界帧数达下限才判错。用于「有没有持续出现」类缺陷（膝内扣、躯干前倾）
- `MIN` / `MAX`：对相位窗口取极值再比阈值。用于「有没有达到某个位置」类判据（下蹲深度）

下蹲深度若用帧计数，底部相位里下降与回升的过渡帧（膝角从 135° 扫到 90° 再回到
143°）会全部算作越界，于是**每个动作都被判深度不足**。

### 6. 决策请求的字段有一些不显眼的约束

不要凭感觉拼 JSON。**照 `shared/contracts/decision_request.schema.json` 生成模型**，
它包含：

- `schema_version` 必填（不给默认值，陈旧客户端漏传时不会被静默当作当前版本）
- `candidates` 最多 20 项（超过这个数 Laya 准确率急剧下降）
- 未知字段一律拒绝（多传字段会在服务端 400，而不是被忽略）
- `thresholds_version` 必填（没有它，历史决策无法复现）

---

第 7–13 条是 Dart 移植这一轮新踩出来的，性质与上面一样：
**照直翻译 Python 会出错，而且不会报错。**

### 7. `catch` 的边界：Dart 的 `TypeError` 是 `Error`，不是 `Exception`

Python 的 `except Exception` 捕得到 `TypeError`（对 `None` 做算术语算就是它）。
Dart 的 `TypeError` 属于 `Error` 分支，**`on Exception` 捕不到**。

状态机把「guard 抛异常」一律记为「本帧不满足」，而「guard 遇到 null」恰恰是
最常见的坏数据情形（铁律二要求不可用特征输出 null）。照搬 `on Exception` 会让
一帧缺数据的信号打断整个实时循环 —— 而那正是这份设计明确要避免的事。

**结论：那条路径必须 `catch (_)`，不能加类型限定。**

### 8. `Map[]` 返回 null，Python 的 `dict[]` 抛 `KeyError`

`severitySpan: _severitySpan['INSUFFICIENT_DEPTH']` —— Python 里键拼错会抛
`KeyError`（响亮），Dart 里只返回 `null`（静默）。后果是该规则悄悄失去严重度
归一，UI 排序跟着失真，而没有任何报错。

**加 `!` 把那份响亮找回来。** 凡是「查表取值、缺了就不对」的地方都要这样。

### 9. `round(x, 4)` 不是同一个函数

Python 的 `round()` 对 double 的真实二进制值做十进制正确舍入、逢半取偶；
Dart 没有对应物，`rules.dart` 用的是 `(x * 10000).round() / 10000`（逢半远离零）。
两者只在「正好落在十进制中点上」时分歧，幅度 ≤ 1e-4。

**若将来给规则输出加 golden fixture，这里是第一个要对齐的地方。**

### 10. Python 的切片会收敛，Dart 的 `sublist` 会抛

`frames[start:end+1]` 越界时自动夹取；`sublist(start, end)` 越界抛 `RangeError`，
而且 `start > end` 也抛。相位边界由状态机产出，一个算错的边界不该让整组动作
判定失败 —— `RepWindow.select` 因此显式夹取，并把空区间当作空列表返回。

### 11. 一份配置、两处入口（Dart 侧已收成一处）

Python 允许 `build_squat` 与 `ActionRunner` 各接一份 `TrackingConfig`，
而两者各只用其中一部分：定义用分段守卫的参数（`min_bend_deg` 等），
runner 用防抖与超时（`vote_window`、`max_rep_frames`）。

**只传一边不会报错**，只会让另一半静默用回默认值 —— 写第一个端到端测试时就踩了：
给 `buildSquat` 传了 `maxRepFrames` 却没给 runner 传，于是「超时丢弃」这条路径
根本没被触发，而测试只是安静地断言失败，看起来像实现的问题。

Dart 侧把配置收进 `ActionDefinition.config`，`ActionRunner` 不再接这个参数。

### 12. ML Kit 的关键点枚举：按索引映射，不要按名字

两边的 33 点顺序逐位一致，但**嘴部两点叫法不同**：ML Kit 是
`leftMouth`/`rightMouth`，本项目按 BlazePose 规范名是 `mouthLeft`/`mouthRight`
（与 Python 的 `L.MOUTH_LEFT` 一致）。按名字映射会让这两个点取不到值，
而引体向上的下颌过杠近似正要用它们。

`platform/mlkit_pose_mapper.dart` 因此按索引映射，并用
`landmarkAlignmentProblems()` 做校验；单元测试再把「豁免名单有且只有两条」
钉死 —— 否则将来 ML Kit 改别处的命名时，会被一份悄悄变长的豁免名单盖过去。

### 13. camera 0.12 的 `CameraImage` 换代了

它现在是 `camera` 包自己的类，不再是 platform_interface 里的 `CameraImageData`；
字段是 `format.group` / `planes[].bytes`，而且**没有** `rotation` ——
旋转角要从 `CameraDescription.sensorOrientation` 取。

NV21 是半平面格式：Y 分量之后紧跟着交错的 VU，而 ML Kit 要一整块连续缓冲，
所以各平面必须拼起来。**只传第一个平面不会报错**，只会让模型在一张
「上半截正常、下半截是垃圾」的图上推理，表现为关键点乱飞或频繁检不到人。

---

## 四、怎么验证做对了

### 特征层：golden fixtures

`shared/fixtures/feature_conformance.json` 有 10 个场景 × 全部 31 个特征。
写一个参数化测试：

1. 按场景的 `overrides` / `mirrored` / `occluded_landmark_visibility` 重建 `PoseFrame`
2. 用同样的 `camera_view` 跑 Dart 版特征提取
3. 逐特征比对：期望 `null` 则必须 `null`，否则 `abs(实际 - 期望) <= 1e-4`

**不要复用 Python 的构造代码，独立重写一遍场景重建** —— 「重建」本身也是被验证的一环。

其中三个场景是专门防回归的，别删：
`squat_bottom_parallel`（负零）、`squat_bottom_parallel_facing_left`（象限）、
`standing_asymmetric_knee`（左右不串用关键点）。

### 状态机：合成序列

参考 `domain/tests/test_exercises.py` 里 `squat_sequence()` 的做法：按「弯曲程度」
插值合成一段深蹲帧序列，断言计数值与三个相位都切出来了。

**再合成一段刻意抖动的序列**（在阈值附近反复穿越），断言不会重复计数 ——
这是三条防抖机制存在的唯一理由。

### 端到端：直接打服务

笔记本上 `python -m app.api` 起服务，App 里把请求 POST 到
`http://<笔记本IP>:8080/v1/decide`。手机开热点、笔记本连热点，全程不碰外网。

---

## 五、几件容易被忽略的事

**帧率与帧率不是一回事。** 预览 30fps、推理 10–15fps 是正常且推荐的 ——
把每一帧都送去推理只会让机器发烫降频。用「只保最新帧」的策略丢帧。

**必须 warm-up。** 首次推理有额外开销，App 启动时拿一张假图跑一次，
否则用户第一次做动作的前几帧会被吃掉。

**相机帧格式要对。** Android 显式请求 `ImageFormatGroup.nv21`，
iOS 用 `bgra8888`。格式不匹配会直接报错或黑屏。
`camera_android_camerax` 需 ≥ 0.6.23（该版本修复了 NV21 被错误标记的长期问题）。

**机位自检要早做。** 人在画面里的比例、正侧视判别、关键点是否被遮挡 ——
这些应该在开始计数**之前**就提示，而不是等用户做完一组才告诉他数据没法用。
参考 `docs/domain-layer-design.md` §2.4 的检查清单。

---

## 六、遇到分歧怎么办

**以 Python 参考实现为准。** 它不是随手写的草图 —— 每条设计决定都有文档说明，
而且每条都有对应的测试。

如果你认为 Dart 侧应该做得不一样（例如某个算子可以更快），
**先把 fixtures 跑过再说**。数值一致是底线；在不一致的前提下谈优化没有意义，
因为不一致带来的准确率损失远大于任何微优化收益。
