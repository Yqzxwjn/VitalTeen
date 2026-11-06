# Phase 0 · 环境搭建与技术验证清单

> 周期：第 1 周
> **这一阶段的目标不是"准备好"，而是"尽早证伪"。**
> 如果 Flutter 路线达不到实时帧率，必须在本周内知道，而不是第 10 周。

---

## 一、为什么要单独做这一周

本项目有三条技术假设，任何一条不成立都要重新选型：

| 假设 | 若不成立的后果 | 验证方式 |
|---|---|---|
| Flutter 层能稳定跑到 ≥15 FPS 姿态推理 | 整个端侧方案作废，退回原生 Android Kotlin | §四 真机实测 |
| ML Kit bundled 模式真能完全离线 | 答辩演示依赖网络，风险不可接受 | §四 断网实测 |
| Laya 在笔记本 CPU 上单次决策 < 2 秒 | 决策层体验受损 | §五 实测记录 |

**先用官方 example 验证，不要先写业务代码。** 官方 example 跑不通就改代码，是最常见的浪费。

---

## 二、本机需要安装什么

当前状态（2026-10-04 实测）：

| 组件 | 状态 |
|---|---|
| git 2.55 / winget 1.29 | ✅ 已装 |
| Python 3.11.9 + pip | ✅ 已装 |
| D 盘可用空间 472 GB | ✅ 充足 |
| **Flutter SDK** | ✅ 3.47.6（`D:\dev\flutter`，走 `storage.flutter-io.cn`） |
| **JDK** | ✅ Android Studio 自带的 JBR —— 但版本是 **25**，不是计划里推荐的 17，见 §2.1 |
| **Android SDK / 平台工具** | ✅ 随 Android Studio 装好（`%LOCALAPPDATA%\Android\Sdk`） |
| **真机** | ✅ 22101316UCP · Android 14 · arm64-v8a |

### 2.1 JDK：实际用的是 Android Studio 自带的 JBR 25（与计划不符）

**本机实测（2026-10-04）**，`flutter doctor -v` 的输出：

```
Java binary at: D:\Android\jbr\bin\java
Java version:   OpenJDK Runtime Environment (build 25.0.3+-15898627-b508.16)
```

三件事要说清楚：

1. **Android Studio 装在 `D:\Android`**，不是默认的 `C:\Program Files\Android\Android Studio`。
   所以 `JAVA_HOME` 未设置、PATH 上也没有 `java` —— 这**不是问题**，
   Flutter 自己知道去哪里找。别看到 `java -version` 报「找不到命令」就去装一个 JDK，
   那反而可能装出第二个版本、把构建搞乱。判断依据看 `flutter doctor -v` 那两行。
2. **版本是 25，而本文档此前推荐 17。** 开发计划里写着「不要用 JDK 21+，
   部分 Android Gradle 插件版本对高版本 JDK 兼容性不佳」—— 那条建议针对的是更早的
   AGP/Gradle 组合。本机是 AGP 9.1.0 + Gradle 9.3.1，实测配置阶段不报错。
3. **但若构建出现 JDK 相关的诡异报错，第一个要试的就是换回 JDK 17**：

   ```bash
   winget install --id Microsoft.OpenJDK.17
   flutter config --jdk-dir "<JDK17 安装路径>"    # 或设 JAVA_HOME
   ```

   高版本 JDK 与 Android 工具链的兼容问题，报错往往出现在离病因很远的地方
   （例如某个注解处理器报 `NoSuchMethodError`）。先换 JDK 再查代码。

### 2.2 Flutter SDK

**2026-10 在本机实测的结论**：`winget` 里**没有** Flutter SDK（搜 `flutter` 出来的全是
「用 Flutter 做的应用」，如 AppFlowy、Fladder），所以只能走压缩包。

**下载源实测**（2026-10 实测。**必须看深处速率** —— 只看开头会被误导）：

| 源 | 开头 10MB | 500MB 处 10MB | 结论 |
|---|---|---|---|
| `storage.flutter-io.cn` | 9.70 MB/s | **9.48 MB/s** | ✅ **用这个**，全程稳定 |
| `mirrors.cloud.tencent.com/flutter` | 9.79 MB/s | 4.95 MB/s | ⚠️ 深处掉一半，实测在 **126 MB 处停滞**（降到 22 KB/s） |
| `storage.googleapis.com` | 0.13 MB/s | 0.08 MB/s | ❌ 国内别用 |
| `mirrors.tuna.tsinghua.edu.cn/flutter` | 连不上 | — | ❌ |

> 教训：最初只测了「前 4MB」就写了「腾讯 9.3 MB/s，用这个」，结果**大文件下到
> 126MB 就基本不动了**。镜像对短请求快、对大文件限速是常见做法，
> 测速必须覆盖文件深处才有意义。

当前 stable 版本：**3.47.6**（满足下方要求的 ≥3.44）。

```bash
# 1. 建目录。路径【不含空格与中文】——含空格会让 Gradle 与 NDK 出各种离奇错误
mkdir -p /d/dev && cd /d/dev

# 2. 下载（实测 1933193895 字节 = 1.8 GB；flutter-io.cn 约 9.5 MB/s，三分多钟）
#
#    两个参数是刻意加的：
#      -C -                 断点续传。1.8GB 下载中途断掉很常见，续传省得重来
#      --speed-limit/time   停滞保护：速率掉到 512KB/s 以下持续 25 秒就断开重试。
#                           不加这个的话，连接卡住时 curl 会"成功"地爬很久
curl -L -f -C - --speed-limit 524288 --speed-time 25 -o flutter.zip \
  https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.6-stable.zip

# 下完必须校验：比字节数不够，zip 有自己的 CRC
unzip -t flutter.zip | tail -2

# 3. 解压，得到 D:\dev\flutter
unzip -q flutter.zip && rm flutter.zip

# 4. 配置国内镜像与 Android SDK 位置
setx PUB_HOSTED_URL "https://pub.flutter-io.cn"
setx FLUTTER_STORAGE_BASE_URL "https://storage.flutter-io.cn"
setx ANDROID_HOME "C:\Users\yqzxw\AppData\Local\Android\Sdk"
```

**第 5 步要小心 —— 不要用 `setx PATH "%PATH%;D:\dev\flutter\bin"`。**

那会把系统级的 PATH 整段复制进用户级 PATH，而 `setx` 有 1024 字符上限，
超了会**静默截断**，把系统 PATH 弄坏。用 PowerShell 只追加用户级的那一段：

```powershell
[Environment]::SetEnvironmentVariable(
  'Path',
  [Environment]::GetEnvironmentVariable('Path','User') + ';D:\dev\flutter\bin',
  'User'
)
```

然后**新开一个终端**（`setx` 只影响新开的窗口，当前这个看不到），验证：

```bash
flutter --version     # 应输出 3.47.6
flutter doctor -v
```

> 版本要求：`google_mlkit_pose_detection` 0.16.x 要求 **Flutter ≥ 3.44.0 / Dart ≥ 3.12.0**。
>
> 本机 Android SDK 现状（已由 Android Studio 装好，2026-10-04 实测）：
> `build-tools 36.0.0`、`platforms android-37.0`、`platform-tools`、`licenses` 已接受，
> **`cmdline-tools/latest` 也在**。
>
> `sdkmanager.bat` 已标记弃用（运行时打印 “Android CLI will be used instead”），
> 但**仍能正常工作** —— 实测 `sdkmanager --version` 退出码 0，输出
> `1.0.16500706 (Android CLI)`。它的替代品是 `cmdline-tools/latest/bin/android.exe`，
> 注意**没有 `android.bat`**，路径写 `.bat` 会找不到。

#### NDK：确实要装（2026-10-04）

首次 `flutter build apk` 在**配置阶段**失败，而报错很容易被误读：

```
Package ndk not found.
Package 28.2.13676358 not found.
> org.gradle.api.GradleException: Android sdkmanager did not install NDK 28.2.13676358
```

「Android sdkmanager did not install NDK」读起来像「本机没有 sdkmanager」——
**不是**，它有、也能用（见上）。真因很简单：本机没装 NDK，而 Flutter 那次自动
安装没成功。

**谁需要 NDK**：`jni` 这个包带 `externalNativeBuild` + `CMakeLists.txt`，
由 `camera` 0.12 的 jnigen 绑定间接拉进来。所以它是真的需要，**不能靠删
`ndkVersion` 绕开**：

- 删掉 `app/build.gradle.kts` 里那一行没有用。Flutter 的 `forceNdkDownload`
  会用 `FlutterExtension.ndkVersion` 强制同一个版本，构建照样失败，只是报错
  位置从 `app/build.gradle.kts` 挪到了根 `build.gradle.kts` 的
  `evaluationDependsOn(":app")` —— 反而更难查。
- 这个默认值（`28.2.13676358`）来自 Flutter SDK 自己的 `FlutterExtension.kt`，
  不是模板随手填的。

装它：

```bash
"$LOCALAPPDATA/Android/Sdk/cmdline-tools/latest/bin/sdkmanager.bat" "ndk;28.2.13676358"
# 若卡在许可协议上：yes | sdkmanager.bat "ndk;28.2.13676358"
```

> **排查教训。** 当时只翻了自己直接依赖的两个包（`camera`、
> `google_mlkit_pose_detection`）就下了「整个依赖树没有 native 代码」的结论，
> 而真正带 `CMakeLists.txt` 的是被它们**间接**拉进来的 `jni`。
> 判断「有没有 native 代码」必须遍历整个依赖树：
>
> ```bash
> for f in ~/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/*/android/build.gradle; do
>   grep -l -i -E "externalNativeBuild|CMakeLists" "$f"
> done
> ```

#### Kotlin 增量编译：Windows 跨盘符时必须关掉（2026-10-04）

装好 NDK 之后构建又失败了，这回死在 Kotlin 编译插件子项目上。报错有几百行
Java 栈帧，**真因只在一行 `Suppressed` 里**：

```
Suppressed: java.lang.IllegalArgumentException: this and base files have different roots:
  C:\Users\yqzxw\AppData\Local\Pub\Cache\hosted\...\google_mlkit_commons-0.13.0\android\src\main\kotlin\...\GenericModelManager.kt
  and
  D:\Code\VitalTeen\app\android.
```

**源码在 C:，工程在 D:。** Kotlin 增量编译要把源文件路径存成相对于构建根目录的
路径，而 Windows 上跨盘符算不出相对路径 —— `relativeTo` 直接抛。

修法是 `app/android/gradle.properties` 里加一行（理由也写在那儿了）：

```properties
kotlin.incremental=false
```

代价是 Kotlin 每次全量编译；release 构建本来就是全量，所以只影响 debug 迭代速度。

**两种免于踩坑的布局**：把 pub 缓存也放到 D 盘（`PUB_CACHE=D:\pub-cache`），
或者把工程放到 C 盘。二选一的话，改 `PUB_CACHE` 更彻底（顺带省掉别处的跨盘问题），
但要把已下载的包重下一遍。

### 2.3 Android 开发环境

两条路，二选一：

**路线 A · Android Studio（推荐给零移动经验的团队）**
- `winget install --id Google.AndroidStudio`
- 首次启动时用 SDK Manager 安装：Android SDK Platform 36、Android SDK Build-Tools、Android SDK Command-line Tools、Android SDK Platform-Tools
- 许可协议在 GUI 里点同意，不会卡住

**路线 B · 仅命令行工具（体积小，适合脚本化）**
- 下载 `commandlinetools-win-*.zip`，解压到 `D:\dev\android-sdk\cmdline-tools\latest\`
- 设置环境变量 `ANDROID_HOME=D:\dev\android-sdk`
- 安装组件并接受许可：
  ```bash
  sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"
  yes | sdkmanager --licenses
  ```
- 把 `ANDROID_HOME\platform-tools` 和 `ANDROID_HOME\cmdline-tools\latest\bin` 加进 PATH

### 2.4 国内镜像配置（**不做这一步会卡到怀疑人生**）

**Flutter / Dart 包源** —— 加为系统环境变量：

```
PUB_HOSTED_URL=https://pub.flutter-io.cn
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

备用源：**目前没有实测可用的。** 试过的都不行 ——
`mirrors.cloud.tencent.com/flutter` 深处掉速（实测在 126 MB 处停滞），
`mirrors.tuna.tsinghua.edu.cn/flutter` 连不上。若 flutter-io.cn 也失效，
**先重新测速再决定**，别照着一份「应该能用」的名单挨个试。

**Gradle 仓库** —— 在 `app/android/settings.gradle.kts` 与 `app/android/build.gradle.kts`
里把阿里云镜像**加在最前面**：

```kotlin
maven { url = uri("https://maven.aliyun.com/repository/google") }
maven { url = uri("https://maven.aliyun.com/repository/public") }
maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
```

两个要点：

- **必须放在最前。** Gradle 按声明顺序解析、命中即止 —— 放在 `google()` /
  `mavenCentral()` 之后等于没有，请求会先发去官方源卡在超时上。
- **官方源要保留**，不要删掉。镜像偶尔缺包，Gradle 会回落到后面的官方源；
  删了就没有退路，而「某个传递依赖恰好在镜像里没有」这种事发生得很随机。

**Gradle 发行版** —— 改 `app/android/gradle/wrapper/gradle-wrapper.properties`：

```
distributionUrl=https\://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip
```

**不要等到卡住再改。** 这个包有 200MB 上下（`-all` 含源码与文档），而本机
`~/.gradle` 当时完全是空的 —— 首次构建的时间基本全花在它身上。
2026-10-04 实测各源：

| 源 | 结果 |
|---|---|
| `mirrors.cloud.tencent.com/gradle/` | 200，0.27s ✅ |
| `mirrors.huaweicloud.com/gradle/` | 200，1.16s ✅ 备用 |
| `services.gradle.org` | 307 跳转，2.80s ⚠️ 慢速 CDN |

版本号要跟着 `gradle-wrapper.properties` 里原有的值走（Flutter 模板生成，
别自己改版本），只换主机名。

**Python 包源** —— 各家镜像在本机的实测（2026-10-04，拉 `torch` 的真实索引页看吞吐）：

| 源 | 结果 |
|---|---|
| `mirrors.huaweicloud.com/repository/pypi/simple` | **1.41 MB/s** ✅ 最快 |
| `mirrors.cloud.tencent.com/pypi/simple` | 0.93 MB/s ✅ |
| `pypi.org/simple`（直连） | 0.69 MB/s ⚠️ 意外地能用 |
| `mirrors.aliyun.com/pypi/simple` | 0.24 MB/s ⚠️ 慢 |
| `pypi.tuna.tsinghua.edu.cn/simple` | **连不上** ❌ |

**注意：本文档此前推荐的正是清华 TUNA，而它在这台机器上根本连不上** ——
与它的 Flutter 镜像同一个下场（见 §2.2 的测速表）。这不是说 TUNA 不好，
而是**这条网络到它不通**。所以别照抄任何人的推荐，**每次先测**：

```bash
curl -s -o /dev/null -w "%{http_code} %{speed_download}\n" --max-time 25 \
  https://<镜像>/simple/torch/
```

装 Laya 时用 `-i` 指定本次的源就够了，不必改全局配置：

```bash
pip install "laya[serve]" -i https://mirrors.huaweicloud.com/repository/pypi/simple
```

**HuggingFace 直连实测：15 秒超时，完全不通。** 所以「Laya 权重必须走 ModelScope」
不是保守建议，而是**唯一可行的路径** —— `www.modelscope.cn` 可达（302，0.41s）。

> 顺带一个体量参考：装之前 `.venv` 是 217 MB；`laya[serve]` 会解析出 **34 个包**，
> 其中 `torch` 是绝对大头。所以它不该进 `requirements-dev.txt` ——
> 那是给「跑测试」用的轻量依赖。按 `ml/requirements-train.txt` 的先例，
> 服务端的重依赖另立一份、只装在该装的机器上。

**Hugging Face（Laya 权重）**：直连国内常超时，走 **ModelScope** 镜像。这是 Phase 0 笔记本侧验证的前置条件。

> 镜像可靠性提醒：社区镜像不保证长期可用。但**「多记几套」不等于「都能用」**——
> 本文档的测速表里只有 `storage.flutter-io.cn` 是实测通过的，另外两个都失败过。
> 镜像失效时重新测速，不要照着印象里那份名单去试：**没测过的备用源，等于没有备用源。**

### 2.5 验收

```bash
flutter doctor -v
```

**必须全部打勾。** 出现 `[!] Android toolchain` 通常是没有接受许可，或 `ANDROID_HOME` 没配对。

---

## 三、Android 真机准备

**模拟器不可用于本项目验证** —— 模拟器摄像头帧率极低，且 ML Kit / MediaPipe 的 GPU 路径在模拟器上表现异常。必须用真机。

1. 手机设置 → 关于手机 → 连续点击「版本号」7 次，开启开发者模式
2. 开发者选项 → 开启「USB 调试」
3. USB 连接电脑，手机上确认授权
4. 验证：`flutter devices` 应列出你的手机

> 最低要求 Android 8.0（API 24）。不需要旗舰机，中端机即可——
> 但**演示机要单独挑选**，见 §六。

---

## 四、端侧验证（手机）

### 步骤

**不跑官方 example，用本仓库的探针**（`app/lib/phase0/fps_probe.dart`）。

官方 example 的价值是「它一定是对的，所以失败一定是环境问题」；但它要另外 clone、
另外配依赖，而我们的工程里 `google_mlkit_pose_detection` 与 `camera` 本来就装着。
更重要的是探针跑通之后就是相机页的骨架，不是一次性代码 —— 而它验证的是
**我们这套版本组合**的帧率，那才是真正要回答的问题。

```bash
cd app
flutter build apk --release --target lib/phase0/fps_probe.dart --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n cn.vitalteen.vitalteen_app/.MainActivity
```

**`--target-platform android-arm64` 是省时间的，别省掉。** 依赖里的 `jni` 有 native
代码，不加这个参数会对 arm64-v8a / armeabi-v7a / x86_64 **三个 ABI 各编一遍**，
而探针机就是 arm64-v8a。省掉的三分之二全是白干的。

或直接 `flutter run --release -t lib/phase0/fps_probe.dart -d <设备ID>`。

1. **必须 release 构建。** debug 下 Dart 侧的解释执行与断言会让帧率低到毫无
   参考价值，而且是往保守方向错 —— 可能白白放弃一条本来可行的路线。
   探针在 debug 下会在屏幕顶部打一条红字警告。
2. 站在手机前 2–4 米，让全身入镜（屏幕常亮，系统休眠调长）。
3. 界面上的**推理帧率**才是验收看的那一个数字。旁边还列着**取帧率**（相机的
   上限）与**丢帧率**——把前两者混为一谈是这一步最常见的误读：相机跑 30fps
   而推理只有 8fps 时，只看取帧率会以为一切正常。
4. 控制台每秒打一行 `[probe] ...`，可直接复制进验收记录。5 分钟衰减曲线看的就是它：

   ```bash
   adb logcat -s flutter:* | grep probe
   ```

### 验收标准

| 项 | 标准 | 实测值 |
|---|---|---|
| **摄像头 / 机位** | 用**前置**（产品要用户能一边做动作一边看屏幕） | 前置，`sensorOrientation=270`（后置是 90） |
| 推理帧率 | ≥ 15 FPS 稳定 | **后摄 16–19 FPS**（56 秒内稳定）；**前摄 24 FPS**（初步）。前摄的瓶颈在相机而非推理，见下 |
| 33 个关键点全部输出 | 是（含脚跟 29/30、脚尖 31/32） | 四个脚部点齐全比例 **76–93%**（初步）—— 当时镜头前无人、脚部常出画，正式测量应更高 |
| 首帧延迟 | 记录数值 | 首帧推理约在 t≈2s 完成（含模型加载）（初步） |
| **断网可用** | 开飞行模式后仍正常工作 | ☐ 未测 |
| 连续运行 5 分钟 | 帧率衰减记录，判定是否触发发热降频 | ☐ 未测（初步那一轮只跑了 56 秒） |

> **前置与后置的瓶颈不在同一处，所以两个数字不能互相替代。**
> 后摄：`cam=30fps / infer=16–19fps / drop≈40%` —— **推理跟不上相机**。
> 前摄：`cam=24fps / infer=24fps / infer_ms=19 / drop=1%` —— 推理能跑约 52fps，
> **是相机只给 24fps**。
>
> 这个区别决定优化方向：前摄机位下再去优化推理是白费力气（它已经不是瓶颈了），
> 提帧率只能从相机侧想办法（分辨率、格式、或换机型的摄像头能力）。
> 拿后摄那次「drop=40%」去解释前摄，会得出一个完全错误的结论。
>
> **验收数据必须记在"要发货的那个配置"上**，也就是前置。探针自 2026-10-04 起
> 默认前置，且每行日志都带 `lens=`，正是为了让这件事不靠人记。

#### 前摄的左右语义：数据不翻，显示要翻（2026-10-04 全部定案）

换前置时最该担心的不是画面，而是**左右关键点会不会互换**：一旦 `leftKnee` 与
`rightKnee` 对调，膝内扣和左右不对称会**整体判反**，而画面上完全看不出异常。

**结论分两层，两层方向相反，不要合并成一条：**

| | 是否镜像 | 依据 |
|---|---|---|
| 喂给 ML Kit 的原始缓冲 | **不镜像** | 读源码确认 |
| 前摄预览的显示 | **镜像** | 真机定案 |
| 所以骨架覆盖层（前摄） | **要翻一次** | 上面两条的差值 |
| 骨架覆盖层（后摄） | **不翻** | 两边都不镜像 |

**第一层——数据不镜像，读源码确认：**

- `camera_android` 的 `ImageStreamReader.onImageAvailable`
  （`camera_android-0.10.12/.../media/ImageStreamReader.java:108`）把 Camera2 的
  平面字节原样搬进 event channel，图像流路径上没有任何水平翻转
- 整个插件里唯一与前摄相关的补偿是 `DeviceOrientationManager.getVideoOrientation`
  （同版本 `.../sensororientation/DeviceOrientationManager.java:197`）里的
  `angle *= -1`，而那管的是视频/预览的**旋转**，不是图像流方向
- 探针直接读相机上报的 `sensorOrientation`（前摄 270、后摄 90），本来就不走那条路径

所以 `leftKnee` 在解剖学上是正确的左膝，**膝内扣与左右不对称不会被判反**。

**第二层——预览镜像，真机定案：** 把探针里的「镜像」开关关掉，骨架整体偏到
人脸左侧（脸正好落在 `1 - x` 的位置）；打开后肩对肩、髋对髋、膝对膝精确压合。
这是**肉眼一次翻转得到的，不是推出来的** —— 可见性、点数、帧率在两种情况下
全都是正常的，光看数字永远发现不了。

> **翻必须发生在绘制层，绝不能翻进领域层。** `leftKnee` 的解剖学含义与画面
> 左右无关，翻进去会让所有对称性判定整体反向 —— 那是第一层辛苦确认的成果
> 被第二层的一个便利修正抵消掉。
>
> 因此探针里 `_mirror` **跟着镜头走**（前摄自动 true、后摄自动 false），
> 手动开关只为让人能一眼定案，不是给人调的。

**顺带确认了另一件事**：`pubspec.yaml` 里 `camera_android: ^0.10.12` 是**直接依赖**
（当时为绕开 camerax 崩溃显式加的），所以读的就是真正在跑的那份代码；
`camera_android_camerax` 虽然作为传递依赖还在 lock 里，但没被使用。

#### 关键点坐标是**像素**，不是归一化（2026-10-04，骨架画不出来时才发现）

骨架最初完全不显示。排查掉叠加层尺寸、z 序、重绘接线、平台视图覆盖之后，
打出坐标本身，看到 `nose=(324.9, 248.5)` —— **归一化坐标不可能大于 1。**

打整帧范围定案（`img=640x480 rot=270`，转正后 480x640）：

```
x=[124.9, 258.7]   y=[194.8, 728.1]   hipL=(230.1,460.5) hipR=(169.0,463.3)
```

三条判据指向同一个结论 —— **转正后图像的像素，原点左上，y 向下**：

1. 数值远超 [0,1]，不是归一化；
2. 左右髋都在 y≈461 而非 0，不是髋部原点（ML Kit 其它语言 SDK 里有髋部原点的
   空间，不能想当然）；
3. 鼻 y=194.8、髋 y≈462、最远点 y=728 —— **头到髋 267、髋到脚 266**，几乎严格
   对称，正是站立人体髋部位于身高中点的比例；x 跨度 133.8 对身高 533 约等于
   1:4，正是肩宽与身高的比。空间各向同性。

**坑在插件的平台分歧上**：Android 侧传的是 `poseLandmark.position3D.x/y/z`
（`PoseDetector.kt`），iOS 侧传的是 `landmark.position`（`PoseDetector.swift`）——
**同一个 Dart 字段名，两个平台取的是两套原生字段。** 而 Dart 侧注释只写
「in image frame」，不承诺是归一化还是像素。iOS 侧是否同一量纲**未实测**
（答辩锁定 Android），将来要上 iOS，这是第一件要重新量的事。

**为什么它能藏这么久**：探针此前只用点数统计（`ok(33)`、可见性），
而**点数统计对坐标量纲完全不敏感** —— 33 个点坐标全是垃圾，`ok(33)` 照样打得出来。
是「把坐标画出来」这个动作把它逼出来的。

**修法**：`platform/mlkit_pose_mapper.dart` 按**转正后**的尺寸归一化
（90/270 度交换宽高，0/180 不交换），`PoseFrame` 里存的也是转正后的尺寸 ——
否则 `pixel()` 还原时会按错误的轴缩放，画面表现为骨架被拉扁，
看起来很像「相机没校准」。回归锚点已写进
`test/platform/mlkit_pose_mapper_test.dart`，那几条断言把「像素」这个量纲钉死了。

> **上表标「初步」的三行不是正式记录**：那一轮镜头前没有人，画面里是桌面与笔记本，
> 而且只跑了 56 秒。它的价值在于回答**「这条路走不走得通」**——
> **走得通**：`infer` 稳定在 16–19 FPS，`ImageError` 与 `Could not instantiate` 都是 0。
>
> **正式数据要用 §四 前面那套 5 分钟流程重跑一遍**（有人、全身入画、跑满），
> 再把这一列改成最终值。开发计划要的帧率衰减曲线与发热记录，出自那一次。

**「发热降频」要有数字，不能只在记录里写一句「有点烫」。** 探针本身不报温度，
但 adb 能直接从设备读，**不用改一行代码**：

```bash
adb shell dumpsys battery | grep -i temperature     # 单位是 0.1°C
adb shell cat /sys/class/thermal/thermal_zone*/temp  # 单位是 0.001°C
```

压测**前后各读一次**，和当时的推理帧率一起记。要求是：**帧率掉了多少，要能和
温度升了多少对上。** 只报「5 分钟后从 18fps 掉到 11fps」而说不出为什么，
答辩时一句「是不是发热降频？」就问住了 —— 而这恰恰是开发计划风险表里第 5 条。

### 一次完整的 5 分钟压测（照这个顺序做）

```bash
# adb 在 platform-tools 目录下，见 §二
PKG=cn.vitalteen.vitalteen_app

# 0. 先确认设备在 —— 掉线时后面每条 adb 命令都会"成功返回空"，
#    而空结果看起来和「一切正常」一模一样
adb devices

# 1. 压测前的温度与电量
adb shell dumpsys battery | grep -iE "level|temperature"

# 2. 冷启动 App，并清掉旧日志
adb logcat -c
adb shell am force-stop $PKG
adb shell am start -n $PKG/.MainActivity

# 3. 摆机位（这一步是人的事，不是命令的事）
#    镜头选「前置」（默认）；手机架稳、退到 2–4 米、全身进画面、屏幕常亮。
#    退远一点很关键：前摄视角更宽，但站太近照样只拍得到上半身，
#    而「脚出画」会让 feet= 直接掉到 0%（见 §七 验收项）。
#    —— 画面里没人时 ML Kit 的工作量小得多，数字会偏乐观

# 4. 在**退到镜头前之前**，先点 AppBar 的音量图标试听一次提示音。
#    理由见下面「提示音」一节 —— 这是整条流程里唯一
#    「弄错了要等五分钟才发现」的环节。

# 5. 点 AppBar 的计时器图标，开始 5 分钟压测。
#    它会**先清零全部计数**（验收要的是从干净的零起算的 5 分钟），
#    再起倒计时；到点由手机响提示音。期间不要动手机，尤其别点分辨率按钮。

# 6. 在主机上等。这一条纯粹是等待 —— 计时的权威在手机上，
#    因为**要听到铃声的是站在镜头前那个人，不是坐在笔记本前的人**。
sleep 300

# 7. 压测后的温度与电量
adb shell dumpsys battery | grep -iE "level|temperature"

# 8. 导出数据
adb logcat -d -s flutter:* | grep "\[probe\]" > probe_log.txt
```

#### 提示音为什么走闹钟音量流（2026-10-04）

压测时人站在镜头前、**背对着屏幕**：既看不到倒计时，也不知道什么时候跑完。
所以 AppBar 的计时器到点会响一声。决定成败的只有一件事 —— **走哪条音量流**。

走的是 `USAGE_ALARM`：

```bash
# 验证方式（不用听，直接看音频栈里实际登记了什么）
adb shell dumpsys audio | grep "state:started"
# → ... u/pid:10108/11971 state:started attr:... usage=USAGE_ALARM ...
#        ^uid  ^pid（与 adb shell pidof 对上）        ^就是这一条
```

媒体音量是最容易被随手调到 0 的那条流（看完视频就调低了），而**压测最贵的
失败方式是「跑满五分钟但用户不知道结束了」** —— 那五分钟得重跑。
闹钟流系统默认保留、且绕过勿扰。

两个配套决定：

- **铃声自己停（默认 10 秒）。** 用户看不到屏幕、也就够不到停止按钮；
  一个要手动关的铃声会把「提醒」变成「惩罚」
- **平台侧做三级回退**（闹钟音 → 通知音 → 来电铃声）。部分精简 ROM 没有闹钟铃声，
  而「设备恰好没有那个音」会让整条提醒静默失效 —— 那正是这个功能唯一要避免的
  失败方式
- 震动只是**第二通道**，不是兜底。手机多半架在支架上，震动可能被吸收。
  它失败不影响铃声（整个震动函数吞异常）

这也是探针里唯一的一处原生代码（`MainActivity.kt`），通道名 `vitalteen/probe`。

**怎么读这份数据：**

- 每秒一行。`infer` 是推理帧率、`cam` 是取帧率、`drop` 是丢帧率
- **判「是否发热降频」要把两个数字对上**：帧率掉了多少，温度升了多少。
  只报帧率衰减而说不出原因，答辩时一句「是不是发热降频？」就问住了 ——
  而这正是开发计划风险表里的第 5 条
- `feet=` 是四个脚部点齐全的比例，接近 100% 才算过（见 §七 的验收项）。
  **样本不足 30 帧时打 `n/a` 而不是百分比** —— 那个门槛是有来由的：
  2026-10-04 的一次读数里，界面显示「四个脚部点齐全的比例 100 %（31/31）」，
  而同一张表上「平均可见关键点」只有 2.8，画面里根本没有人；
  那 31 帧是在人刚要出画的尾巴上凑出来的。**百分比形式会让读者默认它是结论，
  而 `31/31` 摆出来就不会** —— 所以界面上样本不足时退回原始计数
- `lens=front/270` 是镜头方向与传感器朝向。**它限定这一行所有数字的适用范围** ——
  前摄（270）与后摄（90）的帧率上限不同，两次测量在日志里长得一模一样却不可比
- 行尾若出现 `err0=`，说明有推理失败，**原因就写在同一行里**，不用另找

> 这份流程里的每条命令都单独验证过；**把 1–8 步连起来跑满 5 分钟，还没有做过。**
> 第一次跑的时候留意第 7 步的数字有没有明显高出第 1 步 —— 那才是「发热」的证据。

**切换分辨率或切换镜头都会重启相机并清零全部计数** —— 这是刻意的：
把两种分辨率（或两个镜头）的数据混在同一个窗口里算帧率没有意义。

但它的副作用很坑：2026-10-04 实测时无意中触发过一次，屏幕上
「累计推理 / 累计取帧」从几十变成 `0 / 1`，而同一时刻控制台仍打着 `cam≈30fps`
（那是切换**之前**那一秒的窗口）。两个数字摆在一起看着像自相矛盾，
如果不意识到切换这件事，会得出「相机一帧都没出」的**错误结论**。

**每种分辨率单独跑一轮**，切换后重新开始计时，并且不要在测量中途点它。

**探针的日志行必须覆盖所有失败路径。** 这是踩过才知道的：第一版 `[probe]` 行只打了
`infer / cam / drop / det / vis`，于是「一次推理都没完成」在日志里只表现为
`infer=0.0fps` —— **看不出是取帧格式被拒、是模型加载失败、还是相机压根没给数据**。
整整一轮排查是靠**截图看屏幕上那两个计数**才继续下去的。

现在那行补上了 `fmt=<原始格式>/<平面数> badfmt=<格式失败数> err=<异常数>`，
并把前三次异常原样打印出来。

**教训是通用的：一个测量工具的每一个失败计数，都要出现在它自己的输出里。**
否则你测到的只是「没成功」，而不是「为什么没成功」——而后者才是你打开它的原因。

### 若帧率不达标，按顺序尝试

1. 采集分辨率降到 640×480
2. 降低推理频率（预览 30 fps / 推理 10–15 fps，隔帧处理）
3. 换用 ML Kit 的 `base` 模型并确认用的是 `STREAM_MODE`
4. 仍不行 → **触发选型决策点**：改用原生 Android Kotlin + MediaPipe Tasks

### 必须记录在案的踩坑

- **相机帧格式**：Android 必须显式请求 `ImageFormatGroup.nv21`，iOS 必须 `bgra8888`。格式不匹配会直接报错或黑屏。
- **`camera_android_camerax` 版本**：0.6.23 之前有「NV21 被错误标记为 YUV420」的长期问题。当前用的是 `camera: ^0.12.1`，该问题已不适用 —— 但**帧格式仍然要显式请求**，默认值不是 NV21。
- **`camera` 0.12 的 API 换过代**：`CameraImage` 现在是 `camera` 包自己的类，字段是 `format.group` / `planes[].bytes`，而且**没有** `rotation` —— 旋转角要从 `CameraDescription.sensorOrientation` 取。另外 NV21 是半平面格式，各平面必须拼成一整块连续字节再交给 ML Kit：**只传第一个平面不会报错**，只会让模型在一张「上半截正常、下半截是垃圾」的图上推理，表现为关键点乱飞或频繁检不到人。详见 [dart-port-guide.md](dart-port-guide.md) 第 13 条。

- **release 包启动即崩 —— R8 把 ML Kit 带进来的 WorkManager 裁掉了一半**（2026-10-04 实际踩到并修复）。
  症状是**没有任何 Dart 日志**的启动崩溃，因为崩在 ContentProvider 初始化阶段，
  Dart 引擎还没起来：

  ```
  FATAL EXCEPTION: main
  java.lang.RuntimeException: Unable to get provider androidx.startup.InitializationProvider:
    java.lang.RuntimeException: Failed to create an instance of androidx.work.impl.WorkDatabase
  ```

  依赖链：`google_mlkit_pose_detection` → `pose-detection-common` →
  `com.google.mlkit:acceleration:16.0.0-beta2` → `androidx.work:work-runtime:2.7.0`
  （2021 年的版本）。它的组件由 AndroidManifest 声明，所以 `WorkManagerInitializer`
  **被保留**（清单里的组件 R8 不裁）；而 R8 认为 `androidx.work.WorkManager` 这个
  **类**没人引用，把它删了。结果是**初始化器活着，被它初始化的东西死了**。

  修法见 `app/android/app/proguard-rules.pro`，完整说明也在那里。

  **这类问题的排查顺序**（每一步都比猜快，而且今天正是靠它把三个错误假设逐个排除的）：

  0. **`adb devices` —— 先确认设备还在。** 设备掉线时 `adb shell pidof` 返回空，
     而**空 pid 看起来和「App 崩了」一模一样**。2026-10-04 就因为这个把一次
     「手机被拔掉」误读成了「又崩了」，差点顺着错误方向继续查。
     同理：脚本里别把「没查到 pid」直接写成「崩了」——那是两种不同的失败。
  1. `adb shell dumpsys activity exit-info <包名>` —— 直接给出进程退出原因，
     不用猜「是不是权限」「是不是崩了」
  2. `adb logcat -d -b crash` —— 完整异常链。**注意别用 `tail` 把最里层的
     `Caused by` 截掉**，那通常才是真正缺失的类名
  3. 栈帧里出现 `gp` / `l4` 这种短名字加 `r8-map-id-...`，就是「R8 开着」的标志
  4. `build/app/outputs/mapping/release/` 下有 `mapping.txt` / `usage.txt` /
     `seeds.txt`：**`usage.txt` 是 R8「移除了什么」的清单**。
     但它按**类**列条目，别一看名字在里面就断定「类被删了」——
     先去 `mapping.txt` 查那个类有没有被**改名**（`原名 -> 新名`）。
     本次的两个中间假设（「类被删了」「类被改名了」）都错在这里。

  **同一个原因的第二种症状：不是崩溃，是功能全废。** 修好上面那个启动崩溃之后，
  App 能正常启动了，但**每一次姿态推理都失败** —— 每秒约 30 条
  `E ImageError: Getting Image failed` 加一条 `NullPointerException`。
  真因仍然是 R8：这次它删掉的是 ML Kit 自己的三个组件注册器的无参构造。

  ```
  W ComponentDiscovery: Could not instantiate com.google.mlkit.vision.pose.internal.PoseRegistrar
  W ComponentDiscovery:   Caused by: java.lang.NoSuchMethodException: ...PoseRegistrar.<init> []
  W ComponentDiscovery: Could not instantiate com.google.mlkit.common.internal.CommonComponentRegistrar
  W ComponentDiscovery: Could not instantiate com.google.mlkit.vision.common.internal.VisionCommonRegistrar
  ```

  实测对比：加 keep 规则前，R8 移除了 **225 个** `com.google.mlkit.*` 类
  （其中 85 个在 `.internal.` 下）；把 ML Kit 也加进规则后降到 **1 个**，
  且那一个是 `ComponentDiscovery` 的成员方法，不是注册器本身。

  **所以排查清单要补一条：release 包「功能莫名失效但不崩」，也要先怀疑 R8。**
  在日志里搜 `NoSuchMethodException` / `ClassNotFoundException` ——
  它们比错误信息本身更接近真因。

  这一条容易走错的地方是：错误信息说「图像转换失败」，于是去查图像格式。
  而格式可能完全正确（实测 `fmt=17/1`，正是 NV21 单平面，`badfmt=0`），
  失败发生在**拿到数据之后**。**报错的位置和出错的位置可以隔得很远。**
- **首次推理卡顿**：有报告首次 `processImage` 延迟明显偏高，建议 App 启动时用一张假图 warm-up 一次。

---

## 五、笔记本侧验证（Laya 决策层）

### 步骤

```bash
python -m venv .venv
source .venv/Scripts/activate
pip install "laya[serve]"

# 权重走 ModelScope 镜像（HF 直连国内常超时）
# 具体环境变量名以你装到的版本为准，务必先用 --help 或文档确认

laya-serve --device cpu
```

发一次最小决策请求：

```bash
curl -X POST http://127.0.0.1:8000/v1/systemone \
  -H "Content-Type: application/json" \
  -d '{"state":{"动作":"深蹲","膝角":"95度"},"questions":{"ok":{"type":"noul","instructions":"该动作是否达标？"}}}'
```

### 验收标准

| 项 | 标准 | 实测值 |
|---|---|---|
| 单次决策延迟 | < 2 秒（模型：`laya-multilingual` 322M） | ☐ |
| 内存峰值 | 记录数值 | ☐ |
| 断网可用 | 权重下载完成后可完全离线 | ☐ |

### 必须记录在案的坑

- **必须用 `laya-multilingual`**，不要用英文版 `laya` —— 后者对中文输入基本失效。
- **版本锁定**：Laya 在开源后两周内从 0.1.1 迭代到 0.3.x，字段名（如 `options` → `criteria`）发生过变更。安装后立刻冻结版本号，写进 `requirements.txt` 并锁定 HF checkpoint revision。
- **`laya-serve` 默认监听 `0.0.0.0:8000` 且无鉴权** —— 必须显式绑 `127.0.0.1` 或配置 API key，不要裸奔在局域网上。
- **TensorFlow 冲突**：环境里若装了 TensorFlow 会导致 transformers 导入死锁，设 `USE_TF=0`。
- **内存**：322M 模型 CPU 峰值约 2.0 GB。这是为什么 2核2G 的云服务器不能用于推理。

---

## 六、演示机挑选（Phase 0 就要定下来）

答辩现场只有一次机会，演示机不能临时找。

| 要求 | 原因 |
|---|---|
| Android 真机，**非鸿蒙 NEXT** | 需确认 ML Kit 可用性 |
| 中端以上、近三年机型 | 老机型发热降频会毁掉演示 |
| **不带保护壳** | 散热直接影响连续运行帧率 |
| 准备至少一台备用机 | 现场故障无备份是不可接受的风险 |
| 提前在目标机型上跑满 5 分钟压测 | 记录帧率衰减曲线，写进答辩材料 |

---

## 七、Phase 0 完成标志

- [ ] `flutter doctor -v` 里**与 Android 相关的那几项**全绿（`[√] Android toolchain`、
      licenses 全部接受）。**不要追求「整页全绿」—— 那几项永远绿不了，也与我们无关：**

      | 项 | 为什么不用管 |
      |---|---|
      | `[!] Flutter` — binary 不在 PATH 上 | `scripts/check_all.py` 自己会去找（它查 PATH、`D:\dev\flutter\bin`、`~/flutter/bin`）。真要修就按提示把 `D:\dev\flutter\bin` 加进**用户级** PATH |
      | `[X] Chrome` | 本项目不做 Web 端；大屏是 Vue，与 Flutter 的 Chrome 目标无关 |
      | `[!] Visual Studio` | 不做 Windows 桌面应用 |
      | `[!] Network resources` | 国内访问 Google 端点的必然结果，等 20 秒然后超时。**不是环境坏了** |
- [ ] 帧率探针（`app/lib/phase0/fps_probe.dart`）在真机上以 release 模式跑通
- [ ] **release 包能启动** —— 这不是废话，是 2026-10-04 实际卡了大半天的一条。
      release 包会在启动时直接崩溃，而 **debug 包全程正常**（debug 不做代码裁剪）。
      成因与排查步骤见 §四 的 R8 两条。
      判据：装 release 包 → `adb shell am start` → 6 秒后 `pidof` 仍有输出
- [ ] **release 包里推理真的在跑** —— **能启动不等于功能在**。同一天里，
      启动问题修好之后，App 跑得很好看，但每一次推理都在失败。
      判据：`[probe]` 行的 `infer` 大于 0，且日志里 `ImageError` 与
      `Could not instantiate` 都是 0
- [ ] **四个脚部点（29/30 脚跟、31/32 脚尖）在检出结果里齐全** ——
      看探针的 `feet=` 字段，接近 100% 才算过；**打 `n/a` 说明样本不足 30 帧，
      那一格不算数，先让人站进画面再读**。
      单列这一条，是因为**整个项目「按 33 点而不是 COCO 17 点设计」全压在这四个点上**：
      没有它们，深蹲的脚跟离地判定与立定跳远的起跳判定都做不了。
      而「平均可见关键点 30」这样的数字**证明不了这一条** —— 少两个点照样是 30
- [ ] **骨架压在身体上，且左右没反** —— 判据是肉眼：举一只手，
      骨架的对应手臂要跟着动，且落在真实手臂上。
      这一条**不能靠任何数字证明** —— 2026-10-04 实测里，坐标量纲错了（像素当成
      归一化）与镜像反了，两次都表现为「可见性、点数、帧率全部正常」，
      只有把骨架画出来才看得见
- [ ] 推理帧率 ≥15 FPS 实测达标，数据记录在案
- [ ] 连续运行 5 分钟：帧率衰减曲线 + 压测前后的设备温度（见 §四）
- [ ] 飞行模式下功能正常（证明真离线）
- [ ] Laya 在本机跑通一次 `noul` 决策，延迟与内存记录在案
- [ ] 依赖版本号已锁定：`app/pubspec.lock`（已提交）、Laya 侧写入
      `server/requirements-serve.txt`
- [ ] 演示机确定，并完成 5 分钟连续运行压测

**全部勾选后进入 Phase 1。若有任何一项不达标，先解决再往下走——不要带着未验证的假设进入开发。**
