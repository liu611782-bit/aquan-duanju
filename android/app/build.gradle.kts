import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名：优先 android/key.properties（本机开发），其次环境变量（CI secrets），
// 都没有时回退 debug 签名——保证任何环境都能出可安装的包。
val keystoreProperties = Properties().apply {
    val keyPropsFile = rootProject.file("key.properties")
    if (keyPropsFile.exists()) {
        keyPropsFile.inputStream().use { load(it) }
    }
}

fun signingValue(propName: String, envName: String): String =
    keystoreProperties.getProperty(propName) ?: System.getenv(envName) ?: ""

val ksPath = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")
val ksPassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
val ksAlias = signingValue("keyAlias", "ANDROID_KEYSTORE_ALIAS")
val ksKeyPassword = signingValue("keyPassword", "ANDROID_KEYSTORE_KEY_PASSWORD")
val hasReleaseSigning =
    listOf(ksPath, ksPassword, ksAlias, ksKeyPassword).all { it.isNotEmpty() }

android {
    namespace = "com.aquan.duanju"
    compileSdk = flutter.compileSdkVersion
    // 固定与 CI 安装的版本一致，避免 gradle 现场再下载另一份 NDK。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.aquan.duanju"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(ksPath)
                storePassword = ksPassword
                keyAlias = ksAlias
                keyPassword = ksKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    // 应用内更新：FileProvider（API 24+ 不允许 file:// 跨应用暴露 APK）。
    implementation("androidx.core:core-ktx:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
