package cn.vitalteen.vitalteen_app

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.AudioAttributes
import android.media.ExifInterface
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.tts.TextToSpeech
import android.util.Log
import android.view.WindowManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.ArrayDeque
import java.util.Locale
import kotlin.math.min

/**
 * Android 侧的几件事，分两类：**窗口本身**（[onCreate] 里那一段，见那里的注释），
 * 以及**六条极简的原生通道**：
 *
 * - `vitalteen/probe` —— 提示音与震动，只服务于 `phase0/fps_probe.dart` 的 5 分钟压测。
 * - `vitalteen/display` —— 屏幕常亮，产品侧的深蹲计数用它。
 * - `vitalteen/speech` —— 语音播报，产品侧两米外的用户靠它读计数。
 * - `vitalteen/profile` —— 个人资料的持久化，见 [loadProfile] / [saveProfile]。
 * - `vitalteen/history` —— 练习记录的持久化，见 [loadHistory] / [saveHistory]。
 * - `vitalteen/avatar` —— 头像，见 [loadAvatarPath] / [startAvatarPick]。
 *   它是这里面唯一**不只是一个 `SharedPreferences` 键**的：头像是一张真的图片，
 *   躺在应用私有目录里，prefs 里那个键只是记着它在哪。
 *
 * 通道之所以**只有这六条**：每一条对应的都是一个「Dart 侧做不到、或者做不
 * 可靠」的能力（见下面各处注释），而不是「原生代码写起来顺手」。凡是 Dart
 * 侧能做的（相机、关键点、阈值、判定），一律不在这条边界上再实现一遍。
 *
 * ## 头像为什么不引 `image_picker`
 *
 * 需要的只是「让用户从相册指一张图，然后我把它拷进来」。`ACTION_OPEN_DOCUMENT`
 * 是系统 API，从 API 19 就有，而且**零权限** —— SAF 给的是一次性授权，
 * 不是读存储的权限，所以 `AndroidManifest.xml` 与 `build.gradle.kts` 都不用动。
 * 插件（包括 `image_picker` 与 androidx 的 `PickVisualMedia`）能提供的是
 * 跨平台与一堆裁剪/压缩参数，而这个应用只需要前者的一半，且只需要 Android 一份。
 *
 * **图片处理也不在 Dart 侧做**：一张 4000×3000 的照片直接解码是 48 MB，
 * 而 `BitmapFactory` 的 `inJustDecodeBounds` + `inSampleSize` 是系统提供的、
 * 解码前就能把尺寸压下来的那一套。用 Dart 侧的 `dart:ui` 做同一件事，
 * 要么全量解码进内存（OOM），要么把这段逻辑在两边各写一遍。
 *
 * ## 资料与历史为什么是两个通道（而不是一个「存储」通道）
 *
 * 三条理由，任一条都够：
 *
 * 1. **一个通道一件事** —— 上面这五条各自都只对应一种能力，这是它一直守着的口径。
 * 2. **测试隔离** —— Dart 侧的假通道是一个只有几个方法的模拟。合成一个之后，
 *    测资料的那几条用例会被历史的方法牵着走，反之亦然。
 * 3. **数据形状不同源** —— 资料是「一份对象反复改写」，历史是「一列事实往后追加」。
 *    它们的写入语义（覆盖 vs. 读改写回）、容量（一份 vs. 封顶 200 条）、
 *    损坏的后果（重填一次 vs. 丢几条记录）全都不一样。
 *
 * 两者**共用同一个 `SharedPreferences` 文件**（[PREFS_NAME]），只是各占一个键 ——
 * 于是「清除本机数据」是删两个键，不是一个文件。
 *
 * ## 语音为什么不引 `flutter_tts`
 *
 * 需要的只是「说一句中文」，而 `android.speech.tts.TextToSpeech` 就是系统 API，
 * 一行依赖都不用加。插件能提供的是**跨平台**与一堆参数（音调、语言包管理、
 * 引擎列举），而这个应用只需要前者的一半 —— 而这个类已经在，通道也是现成的。
 *
 * **真正的风险不在这一层，而在设备上有没有能说中文的引擎。** 演示机只装了
 * `com.xiaomi.mibrain.speech`，没有 Google TTS，且 `tts_default_synth` 是 null。
 * 所以 [say] 会**明确返回「说不出」而不是静默成功** —— 见那里的注释。
 *
 * ## 提示音为什么需要原生代码
 *
 * Flutter 自带的 `SystemSound.play()` 在 Android 上走的是
 * `AudioManager.playSoundEffect`，音量由系统音效流控制、且被大量 ROM 静音，
 * 在「用户站在两米外背着屏幕做深蹲」的场景里等于没有。要**可靠地响**，
 * 只有走闹钟流一条路。
 *
 * **为什么走闹钟流（`USAGE_ALARM`）：** 媒体音量是最容易被随手调到 0 的那条流
 * （看完视频就调低了），而闹钟流系统默认保留、且绕过勿扰。压测最贵的失败方式
 * 是「跑满五分钟但用户不知道结束了」—— 那五分钟得重跑，所以提示音必须
 * 建立在**不依赖用户上次调音量时的心情**的那条流上。
 *
 * 提示音是探针的临时设施，不是产品代码。产品里的语音播报走 `vitalteen/speech`
 *（同一个类里的 [say]）—— 两者的共同点只有「都不引新依赖」，用途并不相干：
 * 这里是**跑完了要听见**，那里是**做动作时不用看屏幕**。
 *
 * ## 屏幕常亮为什么不引 `wakelock_plus`
 *
 * 需要的只是 `FLAG_KEEP_SCREEN_ON` 一个 flag，而这个类已经在。
 * 为一行 Kotlin 引一个插件，换来的是多一个依赖、多一份版本兼容面，
 * 而插件本身在后台也是落在这个 flag 上 —— 中间那层没有提供任何东西。
 */
class MainActivity : FlutterActivity() {

    private var ringtone: Ringtone? = null
    private val handler = Handler(Looper.getMainLooper())
    private var pendingStop: Runnable? = null

    /**
     * 「正在等用户在相册里挑一张图」那次通道调用的答复器。
     *
     * 见 [startAvatarPick]：这次调用跨越了一次 activity 跳转，中间没有任何
     * 地方能猜出答案，所以只能把它存到相册回来为止。`null` ＝ 没有在等。
     */
    private var pendingPick: MethodChannel.Result? = null

    /** 语音引擎。`null` 表示还没建过（惰性），见 [ensureEngine]。 */
    private var tts: TextToSpeech? = null

    /** 引擎初始化完成且语言可用。 */
    private var speechReady = false

    /**
     * 已经确定说不了。一旦为真就不再重试 —— **失败一次就重试一次的循环是最坏的**：
     * 每次都要绑一次系统服务，而结论不会变。
     */
    private var speechFailed = false

    /** 引擎还在初始化时攒下的那一句。 */
    private var pending: String? = null

    /** 连续失败次数，用于区分「偶发」与「真的坏了」。见 [say]。 */
    private var speakFailures = 0

    /**
     * 让内容铺到系统栏底下（边到边）。
     *
     * ## 这一行**不是**那条黑带的解药，别搞混
     *
     * 底部那条 44 物理像素的黑带是 `SystemUI` 画的，它画不画取决于窗口有没有
     * `FLAG_TRANSLUCENT_STATUS` / `FLAG_TRANSLUCENT_NAVIGATION` 两个标志，
     * 而那两个标志只有主题给得了（`values/styles.xml` 的 `VitalWindow`，
     * 那里写了量出来的全过程）。**改这里对黑带没有任何影响** ——
     * 一度以为 `fl` 里的 `LAYOUT_INSET_DECOR` 是病根，是误读：
     * 那个标志 `PhoneWindow.generateLayout()` 给**每一个**非浮动窗口都加
     *（AOSP `PhoneWindow.java:2425-2433`），系统「设置」应用也带着它，
     * 却照样铺满整屏。
     *
     * ## 这一行管的是另一件事：内容要不要给系统栏让位
     *
     * 它决定 `ViewRootImpl` 拿到哪一份 insets 回调（`PhoneWindow` 4002 行起）：
     * 让位（默认）时系统栏的高度会变成内容视图的 padding，Flutter 于是只拿到
     * 一块 0–2356 的画布；不让位时画布是整屏 0–2400，而系统栏高度改由
     * `MediaQuery.padding` 交给 `SafeArea` 去避。
     *
     * **练习页要靠这一点**：相机预览铺满整屏、HUD 浮在画面上，底部那条导航栏
     * 底下要透出相机画面而不是一层页面底色。让位的话那里会露出一条
     * `windowBackground` 的白条，压在深色的练习页上非常显眼。
     *
     * 目标 SDK 是 36，Android 15 起系统本来就会强制边到边，这条路迟早要走；
     * 这里显式走掉，是为了让手上这台 Android 14 跟新机器表现一致。
     *
     * ## 为什么写在 `super.onCreate` 之后
     *
     * `FlutterActivity.onCreate` 里有一句 `setContentView`，它会触发
     * `PhoneWindow.installDecor` → `generateLayout`，而 `generateLayout`
     * 按主题把窗口标志整体重刷一遍。写在 `super.onCreate` 之前会被它盖掉。
     * 写在之后就没有第二次 —— decor 只装一次（`installDecor` 自己判了
     * `mContentParent == null`）。
     *
     * 内容不会因此被系统栏吃掉：Dart 侧每一屏都套了 `SafeArea`
     *（唯一的例外是开屏，它要的就是整幅图铺满，见 `splash_page.dart`）。
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        WindowCompat.setDecorFitsSystemWindows(window, false)

        // Q 起系统会给「透明导航栏 + 底下内容对比度不够」自动补一层蒙版，
        // 浅色页面上它是一条灰带 —— 比黑带浅，但同样不是应用的一部分。
        // 这一条是**必须**关的：本应用全屏几乎都是纯白，正好是那个
        // 「对比度不够」的判定最容易命中的样子。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "alarm" -> {
                        ring(call.argument<Int>("seconds") ?: DEFAULT_SECONDS)
                        result.success(null)
                    }
                    "silence" -> {
                        silence()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DISPLAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepScreenOn" -> {
                        setKeepScreenOn(call.arguments as? Boolean ?: false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPEECH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "speak" -> {
                        val text = call.argument<String>("text") ?: ""
                        result.success(say(text))
                    }
                    "stop" -> {
                        stopSpeaking()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PROFILE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "load" -> result.success(loadProfile())
                    "save" -> result.success(saveProfile(call.arguments as? String ?: ""))
                    "clear" -> result.success(clearProfile())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HISTORY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "load" -> result.success(loadHistory())
                    "save" -> result.success(saveHistory(call.arguments as? String ?: ""))
                    "clear" -> result.success(clearHistory())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AVATAR_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "path" -> result.success(loadAvatarPath())
                    // **这一条不在这个回调里 resolve。** 它把 `result` 存下来，
                    // 等用户从相册回来才回话 —— 见 [startAvatarPick]。
                    "pick" -> startAvatarPick(result)
                    "clear" -> result.success(clearAvatar())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 让用户从相册挑一张图。
     *
     * ## 为什么是 `ACTION_OPEN_DOCUMENT` 而不是 `PickVisualMedia`
     *
     * - **零权限**：SAF 给的是一次性授权，不是读存储权限。所以
     *   `AndroidManifest.xml` 里那条 `READ_MEDIA_IMAGES` 一个都不用加。
     * - **零新依赖**：`androidx.activity` 的 `PickVisualMedia` 要 1.7+，
     *   而 SAF 从 API 19 就有 —— minSdk 24 稳过，也不必为一个选图动作
     *   去看 androidx 的版本矩阵。
     *
     * 代价是选完之后我们**立刻把图拷进私有目录**，不长期持有那个 URI 的读权限
     * （见 [importAvatar]）。这是有意的：一个跨重启仍然有效的 URI 权限，
     * 用起来要记着在合适的时机 `releasePersistableUriPermission`，而
     * 这个应用不需要「原图一直在相册里」这件事 —— 它要的只是一张 288 的方图。
     *
     * ## 为什么把 `result` 存起来
     *
     * `startActivityForResult` 是异步的：这里返回之后，要等用户在相册里
     * 按了确定或返回，[onActivityResult] 才会被调到。所以这次通道调用的答复
     * 也推迟到那时 —— 中途没有任何地方能猜出答案。
     *
     * ## 同一时刻只允许一个
     *
     * 再点一次时先把上一个按「取消」结掉。不这么做的话，那个 `MethodChannel.Result`
     * 会被覆盖丢掉，而它的对面（`platform/avatar_store.dart` 里那个 `Future`）
     * **永远不会 resolve** —— 那是一条听起来永远不会结束的等待。
     */
    private fun startAvatarPick(result: MethodChannel.Result) {
        pendingPick?.success(PICK_CANCELLED)
        pendingPick = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("image/*")

        try {
            startActivityForResult(intent, AVATAR_PICK_REQUEST)
        } catch (e: ActivityNotFoundException) {
            // 设备上没有能接这个 intent 的应用（精简 ROM 上真的会发生）。
            // **必须在同一个调用里回话** —— 不像上面那个「等用户回来」的分支，
            // 这一次压根没跳出去，不会有回调来救场。
            pendingPick = null
            Log.w(TAG, "没有能打开相册的应用", e)
            result.success(PICK_FAILED)
        }
    }

    /**
     * 相册回来了。
     *
     * ## 为什么是覆写而不是注册监听
     *
     * 计划里写的是 `activityControlSurface.addActivityResultListener`，
     * **这个方法在这个 embedding 版本里不存在**（`FlutterEngine` 的
     * `getActivityControlSurface()` 只提供 `onActivityResult` 这类分发方法，
     * 注册监听的那套接口已经不在了）。覆写 `onActivityResult` 是这里唯一
     * 还成立的写法，而且它不与 Flutter 自己的分发打架 —— 认不出的请求码
     * 一律原样交给 `super`，那才是 Flutter 把结果转给插件的那条路。
     *
     * ## 为什么换个线程做图片处理
     *
     * 一张 4000×3000 的照片，探边界 + 解码 + 旋转 + 缩放是几十到几百毫秒，
     * 全在主线程上就是一次可感的卡顿（而这时用户刚点完相册，正盯着屏幕）。
     * 解出来的 `Bitmap` 可以跨线程传递，`result.success` 则必须回主线程。
     */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != AVATAR_PICK_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingPick ?: return
        pendingPick = null

        val uri = if (resultCode == RESULT_OK) data?.data else null
        if (uri == null) {
            // **用户按返回键退出相册是一次正常操作，不是失败。** 三态的那条
            // 论证在 `platform/avatar_store.dart` 的 `AvatarPickOutcome`。
            result.success(PICK_CANCELLED)
            return
        }

        Thread {
            val path = try {
                importAvatar(uri)
            } catch (e: Exception) {
                Log.w(TAG, "头像导入失败", e)
                null
            } catch (e: OutOfMemoryError) {
                // 一张畸形的大图（比如 50000×50000 的 PNG）能让 `decodeStream`
                // 直接顶到堆上限。**这不是假想** —— `inSampleSize` 只按
                // 像素尺寸算，算得出 1 的那种图仍然可能解不出来。
                // 它是 `Error` 不是 `Exception`，所以上面那个 catch 接不住；
                // 而这里漏掉它，用户看到的是应用直接没了。
                Log.w(TAG, "头像解码时内存不够", e)
                null
            }
            handler.post {
                result.success(if (path != null) PICK_PICKED else PICK_FAILED)
            }
        }.start()
    }

    /**
     * 读资料。没存过就给 `null`。
     *
     * 整个函数吞异常：**一份读不出来的资料必须退化成「再问用户一次」，
     * 而不是一个打不开的应用。** `SharedPreferences` 本身很少抛，但它会
     * 读到一个被清过数据、或被别的版本写坏的文件 —— 那两种情况下这里
     * 返回 `null` 都是正确的答案。格式的合法性由 Dart 侧判定（`Profile.decode`），
     * 这一层不解析内容。
     */
    private fun loadProfile(): String? = try {
        prefs().getString(PROFILE_KEY, null)
    } catch (e: Exception) {
        Log.w(TAG, "资料读取失败", e)
        null
    }

    /**
     * 存资料，返回**是不是真的写下去了**。
     *
     * **`commit()` 而不是 `apply()`，这一点不是风格问题。**
     * `apply()` 立刻返回、落盘在后台线程上，于是它的返回值永远是 `true`
     * —— 而 Dart 侧要拿这个布尔值决定「要不要告诉用户没存上」。用一个恒真的
     * 返回值去回答一个真实的成败问题，等于把那条提示变成永远不会出现的死代码。
     * `commit()` 会阻塞几毫秒，但写的是一个几百字节的字符串，且只在用户按下
     * 「保存」时发生一次。
     */
    private fun saveProfile(raw: String): Boolean = try {
        prefs().edit().putString(PROFILE_KEY, raw).commit()
    } catch (e: Exception) {
        Log.w(TAG, "资料保存失败", e)
        false
    }

    /**
     * 删掉这份资料。返回**是不是真的删掉了**。
     *
     * **`remove(PROFILE_KEY)` 而不是 `clear()`。** `clear()` 会把这个 prefs
     * 文件里的**每一个**键都删掉 —— 包括 [HISTORY_KEY]。而两者共用
     * [PREFS_NAME]，所以那个「顺手清干净」的写法会把用户的练习记录一起抹掉，
     * 而调用方（`platform/local_data.dart`）以为自己只删了资料。
     *
     * 这不是假想的风险：`clear()` 在这里读起来完全合理，而它的后果要到
     * 用户发现「历史也没了」时才现形 —— 那已经是不可挽回的了。
     */
    private fun clearProfile(): Boolean = try {
        prefs().edit().remove(PROFILE_KEY).commit()
    } catch (e: Exception) {
        Log.w(TAG, "资料清除失败", e)
        false
    }

    /**
     * 读一列练习记录。没存过就给 `null`。
     *
     * 与 [loadProfile] 逐条同款：吞异常、不解析内容。**格式的合法性由 Dart 侧
     * 判定**（`decodeHistory`），而且那边是**逐条丢**——一条坏记录不该让
     * 用户的所有历史消失。这一层只搬字符串，所以它连「有几条」都不知道。
     */
    private fun loadHistory(): String? = try {
        prefs().getString(HISTORY_KEY, null)
    } catch (e: Exception) {
        Log.w(TAG, "历史读取失败", e)
        null
    }

    /**
     * 存一列练习记录。返回**是不是真的写下去了**。
     *
     * 同样用 `commit()`（理由见 [saveProfile]）。这里比资料更值得阻塞：
     * **历史是读改写回**，每次保存都全量重写整列 —— Dart 侧拿到 `false` 之后
     * 要做的是「保留盘上原来的那份、并告诉用户这一组没存上」，而那个决定
     * 依赖这个返回值的真实性。
     */
    private fun saveHistory(raw: String): Boolean = try {
        prefs().edit().putString(HISTORY_KEY, raw).commit()
    } catch (e: Exception) {
        Log.w(TAG, "历史保存失败", e)
        false
    }

    /** 删掉全部练习记录。只动 [HISTORY_KEY] 一个键，理由见 [clearProfile]。 */
    private fun clearHistory(): Boolean = try {
        prefs().edit().remove(HISTORY_KEY).commit()
    } catch (e: Exception) {
        Log.w(TAG, "历史清除失败", e)
        false
    }

    /**
     * 当前头像文件的绝对路径。没有就给 `null`。
     *
     * **除了读那个键，还要确认文件真的在。** 键与文件是两样东西，它们会分开
     * 出事：系统清理应用缓存、用户手动删目录、上一次写文件与写键之间被打断 ——
     * 那几种情况下键还在、文件没了。这时返回一个失效路径的后果是
     * 「界面上那个圆一直是空的」，而正确答案是「没有头像，画首字母」。
     *
     * Dart 侧也有一道同样的兜底（`ui/avatar_image.dart` 的 `errorBuilder`）——
     * 两层都留着不是重复：这一层省掉一次必然失败的读盘，那一层防的是
     * 「查完存在之后、真正去读之前」那个窗口。
     */
    private fun loadAvatarPath(): String? = try {
        val path = prefs().getString(AVATAR_PATH_KEY, null)
        if (path != null && File(path).exists()) path else null
    } catch (e: Exception) {
        Log.w(TAG, "头像路径读取失败", e)
        null
    }

    /**
     * 删掉头像文件与那个键。返回**是不是真的删掉了**。
     *
     * 两样都要删，而且**先删文件再删键**：反过来（先删键）时若中途崩了，
     * 那个文件就再也没有人知道它叫什么 —— 它会在私有目录里一直躺着，
     * 而「清除本机数据」的承诺是「这个应用在这台设备上什么都不剩」。
     *
     * 与 [clearProfile] 同一条纪律：只动自己那一个键，不碰 [PROFILE_KEY] /
     * [HISTORY_KEY]。三者共用 [PREFS_NAME]，一次 `clear()` 会把另两样也抹掉。
     */
    private fun clearAvatar(): Boolean = try {
        deleteAvatarFiles()
        prefs().edit().remove(AVATAR_PATH_KEY).commit()
    } catch (e: Exception) {
        Log.w(TAG, "头像清除失败", e)
        false
    }

    /**
     * 删掉私有目录里所有 `avatar_` 开头的文件。
     *
     * **按前缀全删，不是只删当前那一个。** 每次换头像都写一个新文件名
     *（见 [importAvatar] 里那条时间戳的理由），所以正常情况下这里只有一个；
     * 但万一上一次写在删旧文件之后、写键之前被打断了，这里就会多出一个
     * 没人记得的残件。按前缀扫一遍是最省事、也最不会漏的做法。
     */
    private fun deleteAvatarFiles() {
        val stale = filesDir.listFiles { file ->
            file.isFile && file.name.startsWith(AVATAR_PREFIX)
        } ?: return
        for (file in stale) {
            if (!file.delete()) Log.w(TAG, "残留头像删不掉：${file.name}")
        }
    }

    /**
     * 把用户选的那张图搬进私有目录，返回新文件的绝对路径。失败给 `null`。
     *
     * 四步，每一步都在解决一个具体的坏结果：
     *
     * 1. **先探边界、再解码。** 一张 4000×3000 直接解码是 48 MB，
     *    而 `inJustDecodeBounds` 能在不解码的情况下读出尺寸，据此算出
     *    `inSampleSize`。[sampleSizeFor] 保证解码后的短边 ≥ [AVATAR_SIZE_PX]。
     * 2. **按 EXIF 摆正。** 竖着拍的照片，像素在文件里是横躺的，靠 EXIF 的
     *    `TAG_ORIENTATION` 说该怎么转。不加这一步，用户选一张竖拍的自拍，
     *    头像会是躺倒的 —— 而且看起来像是我们把图弄坏了。
     * 3. **居中裁成正方形。** 用户不该为了换个头像先去裁图。圆形的裁切由
     *    Dart 侧（`ClipOval`）负责，这里只保证宽高相等，否则铺进圆里会被拉扁。
     * 4. **缩到 [AVATAR_SIZE_PX] 并压成 JPEG。** 288 是按最高显示尺寸（96）
     *    的三倍留的，与 `docs/brand-assets.md` 那张 `avatar.webp` 同一个数。
     *
     * ## 文件名为什么带时间戳
     *
     * Flutter 的 `ImageCache` 按 (路径, 缩放) 缓存 —— **同一个路径换了图也不会
     * 重新读**。文件名带上时间戳之后路径就变了，缓存自然不命中，换头像立刻生效，
     * 全程不必去碰 `evict()`（那需要 Dart 侧知道缓存的键，而它不该知道）。
     */
    private fun importAvatar(uri: Uri): String? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, bounds)
        }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight)
        }
        val decoded = contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, options)
        } ?: return null

        val upright = applyExifOrientation(uri, decoded)
        val square = centerCropSquare(upright)
        val scaled =
            Bitmap.createScaledBitmap(square, AVATAR_SIZE_PX, AVATAR_SIZE_PX, true)

        // 写新的之前先把旧的清掉。反过来（先写后删）会让「新文件已落盘、
        // 但盘上有两个 avatar_」这个状态存在一会儿，而按前缀全删的
        // [deleteAvatarFiles] 会把新写的那个也删掉 —— 那是个静默的空头像。
        deleteAvatarFiles()

        val file = File(filesDir, "$AVATAR_PREFIX${System.currentTimeMillis()}$AVATAR_SUFFIX")
        file.outputStream().use { out ->
            scaled.compress(Bitmap.CompressFormat.JPEG, AVATAR_QUALITY, out)
        }

        // **不 recycle 中间那几个 `Bitmap`。** `createBitmap` / `createScaledBitmap`
        // 在原图已经符合要求时会**把同一个实例原样还回来**（SDK 的行为），
        // 于是一句无条件 `recycle()` 可能释放掉还在用的那一张，
        // 表现是下一次 `compress` 抛 "Can't call compress on a recycled bitmap"。
        // 这几张图经过 `inSampleSize` 之后都只有几百 KB，交给 GC 是划算的。

        val stored = prefs().edit().putString(AVATAR_PATH_KEY, file.absolutePath).commit()
        if (!stored) {
            // 键没写下去，那个文件就是没人认领的残件 —— 当场删掉，
            // 否则「清除本机数据」要等到下一次换头像才顺手清到它。
            if (!file.delete()) Log.w(TAG, "写键失败后残留的头像删不掉：${file.name}")
            return null
        }
        return file.absolutePath
    }

    /**
     * 让解码后的短边 **≥ [AVATAR_SIZE_PX]** 的前提下取最大的 [BitmapFactory.Options.inSampleSize]。
     *
     * `inSampleSize` 只能是 2 的幂（小于 1 会被当成 1），所以这里是
     * 「一路乘 2 直到再乘一次就低于目标」。
     *
     * 边界：短边本来就小于 [AVATAR_SIZE_PX] 时返回 1 —— 返回更大的话
     * 会把一张小图缩得更小，而我们要的是「不浪费内存」，不是「压到 288 以下」。
     */
    private fun sampleSizeFor(width: Int, height: Int): Int {
        val shortSide = min(width, height)
        var sample = 1
        while (shortSide / (sample * 2) >= AVATAR_SIZE_PX) sample *= 2
        return sample
    }

    /**
     * 按 EXIF 里记的方向把图摆正。没有方向信息、或是 [ORIENTATION_NORMAL] 时原样返回。
     *
     * 走 `ExifInterface(InputStream)` 而不是 androidx 那一份：这个构造器
     * **API 24 就有**（minSdk 24），所以不必为了读一个整数再引一个依赖。
     *
     * 失败时返回原图而不是 `null`：方向读不出来最多是「图可能躺着」，
     * 而返回 `null` 会让整次选图失败 —— 前者能修，后者要重选一次。
     */
    private fun applyExifOrientation(uri: Uri, bitmap: Bitmap): Bitmap {
        val orientation = try {
            contentResolver.openInputStream(uri)?.use { stream ->
                ExifInterface(stream).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "EXIF 读取失败，按不旋转处理", e)
            null
        } ?: ExifInterface.ORIENTATION_NORMAL

        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            else -> return bitmap
        }

        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    /**
     * 居中裁成正方形。宽高本来就相等时原样返回（不白造一张）。
     *
     * **居中而不是别的锚点**：头像是个人脸，而拍人时脸在中间 ——
     * 从左上角裁会把脸切掉一半。真正要做到「以脸为中心」得有人脸检测，
     * 那个代价远超这个位置值多少。
     */
    private fun centerCropSquare(bitmap: Bitmap): Bitmap {
        val side = min(bitmap.width, bitmap.height)
        val x = (bitmap.width - side) / 2
        val y = (bitmap.height - side) / 2
        if (x == 0 && y == 0) return bitmap
        return Bitmap.createBitmap(bitmap, x, y, side, side)
    }

    private fun prefs() =
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun onDestroy() {
        silence()
        stopSpeaking()
        // **还等着用户从相册回来的那一次调用，在这里结掉。**
        // 这一次 activity 已经是最后一次有机会回话的地方了：销了之后
        // [onActivityResult] 再也不会来，而对面（`platform/avatar_store.dart`
        // 里那个 `Future`）会永远等下去。按「取消」结是对的 —— 那次选图
        // 确实没有发生过。
        //
        // 包 try 是因为引擎可能已经先一步拆了，那时候往通道里写会抛 ——
        // 而这里已经没有任何补救手段了，不值得为一个收尾动作把 onDestroy 弄炸。
        try {
            pendingPick?.success(PICK_CANCELLED)
        } catch (e: Exception) {
            Log.w(TAG, "收尾取消选图时通道已不可用", e)
        }
        pendingPick = null

        // **必须 shutdown。** TTS 引擎是个跨进程的绑定服务，不显式断开的话
        // 每次进这个页面都会再绑一个，一路累积到系统拒绝服务为止。
        tts?.shutdown()
        tts = null
        super.onDestroy()
    }

    /**
     * 播提示音并震动，[seconds] 秒后自动停。
     *
     * **自动停是必须的，不是体贴。** 用户看不到屏幕、也就够不到停止按钮，
     * 一个要手动关的铃声会把「提醒」变成「惩罚」—— 他得走过来解锁手机才能让它闭嘴。
     */
    private fun ring(seconds: Int) {
        silence()

        // 依次退到通知音、来电铃声。**三级回退而不是只用闹钟音**：
        // 部分精简 ROM 没有闹钟铃声，而「设备恰好没有那个音」会让整条提醒
        // 静默失效 —— 那正是这个功能唯一要避免的失败方式。
        val tone = sequenceOf(
            RingtoneManager.TYPE_ALARM,
            RingtoneManager.TYPE_NOTIFICATION,
            RingtoneManager.TYPE_RINGTONE,
        ).mapNotNull { type ->
            val uri: Uri? = RingtoneManager.getDefaultUri(type)
            uri?.let { RingtoneManager.getRingtone(applicationContext, it) }
        }.firstOrNull()

        if (tone != null) {
            // 显式指定 USAGE_ALARM：`RingtoneManager.getRingtone` 推出来的流类型
            // 在各版本上不完全一致，而**这个功能的成败就押在「走哪条流」上**，
            // 不能留给默认值去决定。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                tone.audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            }
            ringtone = tone
            tone.play()
        }

        vibrate()

        val stop = Runnable { silence() }
        pendingStop = stop
        handler.postDelayed(stop, seconds * 1000L)
    }

    private fun silence() {
        pendingStop?.let { handler.removeCallbacks(it) }
        pendingStop = null
        ringtone?.let { if (it.isPlaying) it.stop() }
        ringtone = null
    }

    /**
     * 震动作为叠加而不是替代。
     *
     * **别把它当兜底。** 手机多半架在支架上，震动可能被吸收、也可能让画面晃；
     * 它只是提供第二通道，`USAGE_ALARM` 的铃声才是主通道。
     */
    private fun vibrate() {
        // **整个函数吞异常。** 震动只是第二通道，而它失败的方式不少
        //（权限被 ROM 改过、设备没有振动马达、系统省电模式禁振）。
        // 让它把异常抛到方法通道上，等于「震动坏了 → 铃声也不响 →
        // 用户不知道跑完了」，用一个次要信号把主要信号一起赔进去。
        try {
            val vibrator: Vibrator? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)
                        ?.defaultVibrator
                } else {
                    @Suppress("DEPRECATION")
                    getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                }
            if (vibrator == null || !vibrator.hasVibrator()) return

            val pattern = longArrayOf(0, 400, 200, 400, 200, 400)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(pattern, -1)
            }
        } catch (e: Exception) {
            Log.w(TAG, "震动失败，铃声不受影响", e)
        }
    }

    /**
     * 开关屏幕常亮。
     *
     * **不是为了让屏幕「亮着好看」** —— 一组深蹲要 30–60 秒，而这期间用户
     * 两只手都在做动作、不会碰屏幕。系统的息屏时间一到就黑屏，而**黑屏会走
     * `paused`，管线在 `paused` 时会释放相机**（这是对的，后台拿着相机是
     * 资源泄漏）。结果是用户做到第七个，画面自己没了。
     *
     * 走 `FLAG_KEEP_SCREEN_ON` 而不是 `PowerManager.WakeLock`：前者由系统
     * 按「这个窗口是否可见」自动管理，不需要 `WAKE_LOCK` 权限、也不会因为
     * 忘了释放而把 CPU 一直吊着。**忘记释放正是 WakeLock 最常见的事故**，
     * 而这里根本不存在这个问题 —— Activity 一销毁，窗口就没了，flag 随之失效。
     *
     * 失败只记日志：常亮是体验优化，不是功能本身，让它在方法通道上抛出去
     * 会变成 Dart 侧一个 `PlatformException`，而那会打断一局本来能算数的深蹲。
     */
    private fun setKeepScreenOn(on: Boolean) {
        try {
            if (on) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        } catch (e: Exception) {
            Log.w(TAG, "屏幕常亮设置失败", e)
        }
    }

    /**
     * 惰性建引擎。
     *
     * **不在 `configureFlutterEngine` 里建。** `TextToSpeech` 的构造会去绑一个
     * 系统服务，而多数会话里用户根本用不到语音（静音了、或者压根没开始做）。
     * 首次真要说话时再建，代价是头一句可能晚 100–300 ms —— 那由 [pending] 兜住。
     */
    private fun ensureEngine() {
        if (tts != null || speechFailed) return
        tts = TextToSpeech(applicationContext, TextToSpeech.OnInitListener { status ->
            if (status != TextToSpeech.SUCCESS) {
                speechFailed = true
                Log.w(TAG, "TTS 初始化失败：status=$status")
                return@OnInitListener
            }
            configureLanguage()
        })
    }

    /**
     * 初始化回调里配语言与音频属性，然后把攒着的那句说掉。
     *
     * 整个函数吞异常：`onInit` 可能在 Activity 已经开始销毁之后才回来，
     * 那时引擎已经被 `shutdown()`，再调它的方法会抛 `IllegalStateException`。
     * 让它抛出去就是一个没人接的原生崩溃，而这里失败的代价只是「没说话」。
     */
    private fun configureLanguage() {
        val engine = tts ?: return
        try {
            // 先说中文；不行就退到系统默认语言。**演示机上很可能走到退路** ——
            // 系统里只有小米的语音引擎，中文音色要看它装没装。
            // 中英混读总比整句不出声强。
            var result = engine.setLanguage(Locale.SIMPLIFIED_CHINESE)
            if (result == TextToSpeech.LANG_MISSING_DATA ||
                result == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                Log.w(TAG, "没有中文语音数据，退到系统默认语言")
                result = engine.setLanguage(Locale.getDefault())
            }
            if (result == TextToSpeech.LANG_MISSING_DATA ||
                result == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                speechFailed = true
                Log.w(TAG, "这个设备没有可用的语音合成语言包")
                return
            }

            // 走「导航播报」这一档而不是闹钟流：**语音和探针提示音的取舍相反。**
            // 提示音要的是「绝不被静音」，语音要的是「别把用户正在放的音乐打断」——
            // 这一档跟媒体音量走，系统会做闪避（ducking）而不是掐掉音乐。
            engine.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            speechReady = true
        } catch (e: Exception) {
            speechFailed = true
            Log.w(TAG, "TTS 配置失败", e)
            return
        }

        pending?.let { text ->
            pending = null
            tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, UTTERANCE_ID)
        }
    }

    /**
     * 说一句 [text]，返回**引擎接下了没有**。
     *
     * 返回值不是「说完了没有」，是给 Dart 侧判断「这台设备是不是哑的」用的。
     * `true` 包含「已经说上」和「引擎正在初始化、先攒着」两种 —— 后者也算数，
     * 否则每次冷启动的头一句（正是那句「站直，别动」）都会被误报成不可用。
     *
     * **`QUEUE_FLUSH` 而不是 `QUEUE_ADD`：报数晚到等于报错数。**
     * 用户做 squat 的速度可能快过合成一句话的速度，排队会让播报落到现实后面
     * —— 他做完第九个，耳边还在说六。宁可把上一句掐掉说最新的。
     */
    private fun say(text: String): Boolean {
        if (text.isEmpty()) return true
        if (speechFailed) return false

        if (!speechReady) {
            ensureEngine()
            if (speechFailed) return false
            if (!speechReady) {
                // 与 `QUEUE_FLUSH` 同一条策略：只保最新的一句。
                pending = text
                return true
            }
        }

        val engine = tts ?: return false
        if (engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, UTTERANCE_ID) ==
            TextToSpeech.SUCCESS
        ) {
            speakFailures = 0
            return true
        }

        // 偶发的一次失败不该把语音永久关掉 —— 那会让用户在一个只是打了个嗝的
        // 引擎上看到「本机语音不可用」，然后一路看屏幕做完。攒够几次才认。
        speakFailures++
        Log.w(TAG, "语音播报失败（第 $speakFailures 次）：$text")
        if (speakFailures >= MAX_SPEAK_FAILURES) speechFailed = true
        return false
    }

    private fun stopSpeaking() {
        pending = null
        tts?.stop()
    }

    private companion object {
        const val TAG = "VitalTeen"
        const val CHANNEL = "vitalteen/probe"
        const val DISPLAY_CHANNEL = "vitalteen/display"
        const val SPEECH_CHANNEL = "vitalteen/speech"
        const val PROFILE_CHANNEL = "vitalteen/profile"
        const val HISTORY_CHANNEL = "vitalteen/history"
        const val AVATAR_CHANNEL = "vitalteen/avatar"
        const val PREFS_NAME = "vitalteen"
        const val PROFILE_KEY = "profile_v1"
        // 与 PROFILE_KEY 同一个 prefs 文件，各占一个键 —— 所以清除本机数据是
        // 删两个键，不是删文件（见文件头那条理由）。
        const val HISTORY_KEY = "history_v1"
        // 头像的键。它记的是私有目录里那个文件的**绝对路径** ——
        // 图片本身不在 prefs 里，所以清除本机数据要删的是「一个键 + 一个文件」。
        const val AVATAR_PATH_KEY = "avatar_path_v1"

        /** 头像文件在私有目录里的命名。带时间戳的理由见 [importAvatar]。 */
        const val AVATAR_PREFIX = "avatar_"
        const val AVATAR_SUFFIX = ".jpg"

        /** 头像边长（像素）。与 `docs/brand-assets.md` 的 `avatar.webp` 同一个数。 */
        const val AVATAR_SIZE_PX = 288

        /** JPEG 质量。288×288 的头像在 90 下大约十几 KB，肉眼看不出压缩痕迹。 */
        const val AVATAR_QUALITY = 90

        /** 拉起相册用的请求码。只在这一条通道上用，所以取一个不撞别人习惯值的数。 */
        const val AVATAR_PICK_REQUEST = 4711

        // 「选图」那一次通道调用的三个答案。**取消不是失败** —— 三态的理由见
        // `platform/avatar_store.dart` 的 `AvatarPickOutcome`。
        const val PICK_PICKED = "picked"
        const val PICK_CANCELLED = "cancelled"
        const val PICK_FAILED = "failed"

        const val DEFAULT_SECONDS = 8
        const val UTTERANCE_ID = "vitalteen"
        const val MAX_SPEAK_FAILURES = 3
    }
}
