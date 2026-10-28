import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// release 签名密钥读取（ADR 0004）：android/key.properties 不入库
// （.gitignore 已排除），含 storeFile/storePassword/keyAlias/keyPassword。
// release 任务缺 key.properties 时直接失败：随机 debug keystore 会让不同机器/不同
// CI 运行产出的 APK 签名不一致，覆盖安装报「签名冲突」；debug 构建不受影响。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}
val isReleaseTask = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
if (!keystorePropertiesFile.exists() && isReleaseTask) {
    throw GradleException(
        "[signing] 缺少 apps/mobile/android/key.properties，拒绝用 debug keystore 产出 release 包。" +
            "随机 debug 签名会让后续版本无法覆盖安装（INSTALL_FAILED_UPDATE_INCOMPATIBLE）。" +
            "本地请运行 `pnpm keystore:android` 生成正式 keystore；CI 请配置 " +
            "ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD 四个 Secrets。",
    )
}

android {
    namespace = "cn.wait.orbit"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 要求启用核心库脱糖（java.time 等在低 API 设备上的支持）
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "cn.wait.orbit"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // 只认正式 keystore；缺 key.properties 的 release 任务已在上面硬失败，
            // 这里保留 null 是为了让 Gradle Sync / debug 任务不因缺签名配置而报错。
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 核心库脱糖所需的 desugar_jdk_libs
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
