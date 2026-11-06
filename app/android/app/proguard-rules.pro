# ---- ML Kit 姿态检测带进来的 WorkManager，不能让它被裁掉 ----
#
# 症状：release 包**启动即崩**，而且没有任何 Dart 日志 —— 崩在 ContentProvider
# 初始化阶段，Dart 引擎还没起来。logcat 只有：
#
#   FATAL EXCEPTION: main
#   java.lang.RuntimeException: Unable to get provider androidx.startup.InitializationProvider:
#     java.lang.RuntimeException: Failed to create an instance of androidx.work.impl.WorkDatabase
#
# 成因（2026-10-04 查清）：
#
#   google_mlkit_pose_detection
#     → com.google.mlkit:pose-detection
#       → pose-detection-common
#         → com.google.mlkit:acceleration:16.0.0-beta2
#           → androidx.work:work-multiprocess:2.7.0
#             → androidx.work:work-runtime:2.7.0
#
# ML Kit 的加速模块带进来一个 **2021 年的 WorkManager 2.7.0**。它的组件由
# AndroidManifest 声明，所以 `WorkManagerInitializer` 会被保留 —— 清单里声明的
# 组件 R8 不裁。但 R8 认为 `androidx.work.WorkManager` 这个**类**没人引用，
# 就把它删了（见 build/app/outputs/mapping/release/usage.txt 里的
# `androidx.work.WorkManager:`）。
#
# 结果：初始化器活着，被它初始化的东西死了 —— 启动即崩。
#
# 这类「只保留了一半」的裁剪是 R8 最典型的坑：它不报错，只在装上真机跑的时候炸。
# 而且**只在 release 出现** —— debug 不做裁剪，所以开发全程正常，直到你打第一个
# 正式包。排查时注意：栈帧里的 `gp` / `l4` / `r8-map-id-...` 就是「R8 开着」的标志。
#
# 修法是把这棵子树整体保住。多出来的体积相对 55MB 的 APK 可以忽略；而简单地
# 屏蔽掉 WorkManager 的初始化器反而更危险 —— ML Kit 的 acceleration 在运行时
# 确实可能用到它，屏蔽掉会埋下一个更隐蔽、更难查的问题。
#
# `androidx.room.**` 一并保留：WorkDatabase 是 Room 生成的，它靠反射按类名加载
# `WorkDatabase_Impl`，Room 的注解与运行时代码被裁掉一半同样会崩。

-keep class androidx.work.** { *; }
-keep class androidx.room.** { *; }

-dontwarn androidx.work.**
-dontwarn androidx.room.**

# ---- ML Kit 自己的组件注册器：同一类问题的第二个受害者 ----
#
# 修好 WorkManager 之后 App 能启动了，但**每一次推理都抛异常**：
#
#   每秒约 30 条  E ImageError: Getting Image failed
#   PlatformException(InputImageConverterError, java.lang.NullPointerException:
#     ... Object.getClass() on a null object reference)
#
# 真因在更早的一行警告里 —— 它只是 W 不是 E，很容易淹没在上面那一大片里：
#
#   W ComponentDiscovery: Could not instantiate com.google.mlkit.vision.pose.internal.PoseRegistrar
#   W ComponentDiscovery:   Caused by: java.lang.NoSuchMethodException: ...PoseRegistrar.<init> []
#   W ComponentDiscovery: Could not instantiate com.google.mlkit.common.internal.CommonComponentRegistrar
#   W ComponentDiscovery: Could not instantiate com.google.mlkit.vision.common.internal.VisionCommonRegistrar
#
# ML Kit 的组件发现机制是**按类名反射创建注册器**，要求它们有公开的无参构造。
# R8 把这些构造当成「没人调用」删掉了，于是三个注册器一个都建不起来 ——
# **ML Kit 从未完成初始化**，pose detector 没有后端，拿到任何图像都失败。
#
# 症状离病因很远：报的是「图像转换失败」，真因是「组件注册失败」。
# 而且 APK 里的模型文件一个不少（`assets/mlkit_pose/*.tflite` 都在），
# 所以往「模型没打进包」那个方向查只会白费时间。
#
# **这是同一个道理的第二次印证：用反射的库，R8 必须给它留名字和构造。**
# 下一次再遇到「release 包某个功能莫名失效」，先搜日志里的
# `NoSuchMethodException` / `ClassNotFoundException` —— 那比错误本身更接近真因。

-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google.android.odml.** { *; }

-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.internal.mlkit_**
-dontwarn com.google.android.odml.**
