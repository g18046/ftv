import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.ftv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.ftv"

        // 1. media_kit 与 QuickJS 强制要求 minSdk 不低于 21
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 2. 避免 QuickJS 与 media_kit 底层 C++ 动态链接库冲突
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
            pickFirsts += "**/libc++_shared.so"
            pickFirsts += "**/libflutter.so"
        }
    }

    buildTypes {
        release {
            // 使用 debug 签名以便生成后直接安装运行
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
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

// 自动生成带“手机版 + 版本号”的 APK 副本（保留原 app-*.apk 以兼容 flutter build apk 校验）
val releaseVersionName = flutter.versionName
tasks.matching { it.name == "assembleRelease" }.configureEach {
    doLast {
        val apkDir = layout.buildDirectory.dir("outputs/flutter-apk").get().asFile
        if (apkDir.exists()) {
            apkDir.listFiles { f -> f.isFile && f.name.startsWith("app-") && f.name.endsWith(".apk") }?.forEach { src ->
                val suffix = src.name.removePrefix("app-")
                val dst = File(apkDir, "ftv-手机版-v$releaseVersionName-$suffix")
                src.copyTo(dst, overwrite = true)
                println("✅ 已生成带版本名称 APK: ${dst.absolutePath}")
            }
        }
    }
}
