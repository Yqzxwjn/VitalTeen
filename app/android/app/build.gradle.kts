plugins {
    id("com.android.application")
    // Flutter Gradle Plugin 必须排在 Android 与 Kotlin 插件之后。
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "cn.vitalteen.vitalteen_app"
    compileSdk = flutter.compileSdkVersion

    // 保留 Flutter 模板的默认值：依赖树里的 camera 0.12 经 jnigen 拉进了 jni
    // （带 externalNativeBuild + CMakeLists），NDK 是真的需要。删掉绕不开 ——
    // Flutter 的 forceNdkDownload 会用同一个版本强制下载，只是报错位置挪到根
    // build.gradle.kts，更难查。
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "cn.vitalteen.vitalteen_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: release 签名还是 debug key，正式发版前要换成自己的签名配置。
            signingConfig = signingConfigs.getByName("debug")

            // 用 proguardFile（单数）**追加**规则，而不是 proguardFiles（复数）——
            // 后者会把 Flutter 自己加的规则一起替换掉。规则见 proguard-rules.pro。
            proguardFile("proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
