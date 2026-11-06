# 健知行绎

**基于开源决策模型的青少年体态智能导引与体质数据可视化平台**

> 「绎」读作 yì，取寻绎、演绎之意。四字可拆为 **健 · 知 · 行 · 绎** ——
> 健康、认知、实践、演绎：把「知道该怎么练」变成「练对」。
>
> 代码仓库沿用英文名 `VitalTeen`（包名、路径、构建标识都用它，
> 与中文品牌名并存，不互相替代）。

> 参赛赛道：全国大学生数字媒体科技作品与创意竞赛 · 数据可视化与智能交互赛道
> 详细开发计划见 [docs/development-plan.md](docs/development-plan.md)；
> 本 README 只描述仓库结构与开发约定。

## 仓库结构

```
VitalTeen/
├── domain/       领域层参考实现（Python）—— 特征算子、状态机、规则引擎   ✅ 已实现
├── server/       决策服务（Flask + Laya）                              ✅ 已实现
├── ml/           数据集管线、微调与评测                                 ◐ 校准评测已实现
├── shared/       跨语言共享资产（golden fixtures、契约 schema、阈值表）  ✅ 已就绪
├── app/          Flutter 手机 App                                     ◐ 5 个动作可用，其余 4 个只有预览
├── web/          Vue3 + ECharts 数据大屏                              ◐ 结构就绪，等数据接入
└── docs/         设计文档
```

`app/` 的 Flutter 工程已建好（`cn.vitalteen.vitalteen_app`），**领域层已整体移植到
Dart 并与 Python 参考实现逐值对齐**：几何算子、姿态帧、滤波、31 个特征、阈值治理、
状态机、规则引擎，以及深蹲、立定跳远、开合跳、俯卧撑、仰卧起坐、跳绳、引体向上、
平板支撑、坐位体前屈九个动作定义，外加一条
「姿态 → 特征 → 状态机 → 规则」的端到端回归。特征层按 golden fixtures 比对，
动作层用合成序列回归 —— 这是端侧移植的分水岭，过了它，摄像头与 UI 才有意义。

**那道分水岭已经过去了**：摄像头、界面、语音、参考分、断网本机判定与报告渲染都已接上，
首页 9 个动作卡**都能真的练**（其中立定跳远、仰卧起坐、坐位体前屈、俯卧撑、平板支撑
这五项进练习页先锁横屏，因为做动作时身体是横着铺开的）。
练完的每一组会记下来，底栏分成**开始运动 / 历史记录 / 体态 / 我的**四页，历史只存在这台设备上。
详细状态见 [app/README.md](app/README.md)。

**当前的门槛是真机帧率**（Phase 0）：如果目标机器上跑不到 15 FPS 的推理帧率，
整条 Flutter 路线都要重新考虑，所以这件事排在任何 UI 之前。验证工具见
`app/lib/phase0/fps_probe.dart`，模块对照与踩过的坑见
[docs/dart-port-guide.md](docs/dart-port-guide.md)。

`web/` 的代码结构已经完整，但**宏观数据集还没接入**，所以页面会显示
「数据未接入」。那是设计使然，不是故障：本平台展示的是外部统计数据，
在没有确定数据来源之前预置任何示例数字，都会在答辩现场经不起一句
「这个数据哪来的」。数据怎么接见 [web/README.md](web/README.md)。

## 当前进度

| 层 | 状态 | 测试 |
|---|---|---|
| `domain/` 领域层 | 完整：几何算子、姿态帧、滤波、31 个特征、阈值治理、规则引擎、状态机，以及深蹲/立定跳远/开合跳/俯卧撑/仰卧起坐/跳绳/引体向上/平板支撑/坐位体前屈九个动作定义 | ✅ |
| `server/` 决策服务 | 完整：契约、Laya 客户端、方案库、文案、决策编排、Flask 接口、跨包适配器 | ✅ |
| `ml/` 校准评测 | 温度拟合与 ECE 已实现；数据集转换与训练样本生成待数据落地 | ✅ |
| `shared/` | 10 个场景 × 31 特征的 golden fixtures、2 份 JSON Schema、74 条待核定阈值 | — |
| `web/` 数据大屏 | 数据契约与校验、地图加载与省名归一化、五个视图、点击下钻；**等真实数据接入才能演示** | ✅ |
| `app/` 端侧 | 领域层 Dart 移植**全部完成**（几何/姿态/滤波/31 个特征/阈值治理/状态机/规则引擎/九个动作定义/ML Kit 适配层）；摄像头、界面、语音、参考分、断网本机判定与报告渲染已接上，首页 9 个动作**都能真的练**（其中 5 个进练习页先锁横屏）；另有打卡 / 连胜 / 等级 / 每日任务（全部从练习记录推导，无第二份存储） | ✅ |

## 三条必须遵守的工程约定

### 1. 领域层有 Python 和 Dart 两份实现，必须保持一致

`domain/`（Python）是**参考实现**，服务于两件事：

- 为微调生成训练特征（`ml/` 依赖它）
- 作为 Dart 端侧移植的基准

两者算出的特征若不一致，模型会静默失效 —— 这是本项目最隐蔽也最致命的一类 bug。
`shared/fixtures/` 里的 golden 测试向量是唯一的裁判。

**任何特征算子的改动，必须同时更新 fixtures，并让两种语言的测试同时通过。**
端侧实现时请先读 [docs/dart-port-guide.md](docs/dart-port-guide.md)。

### 2. 体育阈值与工程默认值严格分离

| 类别 | 存放位置 | 谁有权修改 | 能否驱动扣分 |
|---|---|---|---|
| 体育阈值（关节角合格线、错误严重度切分等） | `shared/thresholds/` | **仅体育专业成员核定** | 仅 `source_type != pending_review` 者 |
| 工程默认值（滤波窗口、可见性门控、最短状态停留等） | 各模块 `config` | 工程师 | 不参与 |

**工程师不得在代码里硬编码任何体育阈值。** 当前阈值表里 74 条**全部为
`pending_review`** —— 这不是遗漏，而是诚实的状态：公开来源里不存在面向中国学生
群体的权威切点。系统现在能跑、能出提示，但**不能扣分**，这是设计使然。

### 3. 只传特征，不传视频

未成年人影像属敏感个人信息。端侧算完特征后只上传结构化 JSON，视频帧不出设备。

## 快速开始

### 领域层

```bash
cd domain
PYTHONPATH=src python -m pytest tests/ -q
PYTHONPATH=src python -m tools.build_fixtures --check   # 校验 fixtures 与实现同步
```

### 决策服务

```bash
cd server
python -m pytest tests/ -q
python -m tools.export_schema --check                   # 校验 schema 与契约同步
VITALTEEN_HOST=127.0.0.1 python -m app.api              # 启动，默认 :8080
```

环境变量：`VITALTEEN_HOST` / `VITALTEEN_PORT` / `VITALTEEN_API_KEY` /
`LAYA_BASE_URL` / `LAYA_API_KEY` / `LAYA_TIMEOUT_S`。

> ⚠️ **绑非回环地址必须配 `VITALTEEN_API_KEY`**，否则拒绝启动。本服务会返回
> 未成年人身体姿态的判定结果，裸奔在局域网上不可接受。（`laya-serve` 出厂
> 监听 `0.0.0.0` 且无鉴权 —— 别重复那个错误。）

### 校准与评测

```bash
cd ml
PYTHONPATH=src python -m pytest tests/ -q
```

### 数据大屏

```bash
cd web
npm install          # 首次；已配好 npmmirror 镜像（见 web/.npmrc）
npm run test         # 单元与组件测试
npm run typecheck    # vue-tsc，开了 noUncheckedIndexedAccess 等严格项
npm run build        # 产出 dist/，可直接用本地静态服务器离线打开
npm run dev          # 本地开发
```

> 大屏需要**两份独立的外部输入**，各自加载、各自失败 —— 缺哪一份只有对应的
> 视图不可用，其余照常：
>
> | 输入 | 位置 | 缺失时的表现 |
> |---|---|---|
> | 宏观统计数据 | `web/public/data/macro-dataset.json` | 整页显示「数据未接入」 |
> | 中国地图边界 | `web/public/maps/china.geojson` | 只有「地图热力」视图不可用 |
>
> 数据格式见 [web/public/data/README.md](web/public/data/README.md)。
>
> ⚠️ **地图数据的来源与授权需在对外使用前确认** —— 当前那份文件里没有任何
> 出处或审图号信息。详见 [web/README.md](web/README.md)。

### 手机 App

```bash
cd app
flutter test        # 全部回归，含与 Python 参考实现的逐值比对
flutter analyze

# Phase 0 帧率验证（需先接通 Android 真机）
flutter build apk --release --target lib/phase0/fps_probe.dart --target-platform android-arm64
```

**第一次构建前先读 [docs/phase0-environment.md](docs/phase0-environment.md)** ——
要配国内镜像、装 NDK、关掉一条在 Windows 跨盘符时必然失败的编译选项，
否则会卡在几个看不出病因的报错上（每一个都有记录）。端侧实现说明见
[app/README.md](app/README.md)。

### 环境搭建

Python 侧见 [requirements-dev.txt](requirements-dev.txt)（本地轻量依赖）；
微调依赖见 [ml/requirements-train.txt](ml/requirements-train.txt)（**只在租用的
GPU 机器上装**）。Flutter 侧见 [docs/phase0-environment.md](docs/phase0-environment.md)。

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/development-plan.md](docs/development-plan.md) | **开发计划**：技术选型、分期安排、模块分工、风险登记、验收方式。2026-10-03 版，环境相关的部分已被下面两份修订，文首有对照表 |
| [docs/domain-layer-design.md](docs/domain-layer-design.md) | 领域层实现规格：关键点约定、特征算子、状态机、错误规则、决策契约、待核定阈值清单 |
| [docs/dart-port-guide.md](docs/dart-port-guide.md) | **端侧实现指南**：要写什么、怎么验证、这一路上踩过的坑 |
| [docs/phase0-environment.md](docs/phase0-environment.md) | 环境搭建与 Phase 0 技术验证清单 |
| [docs/brand-assets.md](docs/brand-assets.md) | **品牌图**：`app/assets/images/` 三张图的来路、抠图与压缩的做法、品牌色从哪几个像素取的、怎么替换 |
| [server/README.md](server/README.md) | **决策服务**：接口、契约约束、喂给模型的文本怎么写、方案库的核定状态、降级路径 |
| [shared/README.md](shared/README.md) | **共享资产总览**：阈值治理、契约导出、fixtures 的作用，以及 shared → app/assets 的单向同步 |
| [shared/fixtures/README.md](shared/fixtures/README.md) | 跨语言一致性测试向量：格式与用法 |
| [ml/README.md](ml/README.md) | 数据集采购清单、微调管线形态、Laya 的已知约束 |
| [web/README.md](web/README.md) | 数据大屏的定位、与 App 的分工、数据源待确认清单 |
| [web/public/data/README.md](web/public/data/README.md) | 宏观数据集的字段规范与两条易踩的规则 |
