plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "br.leolira.saude"
    // O pacote health (Health Connect connect-client 1.2.0-alpha06) exige API 37.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "br.leolira.saude"
        // Health Connect: Android 8 (API 26) ou mais novo.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Assinatura fixa: o GitHub Actions grava app/android/app/saude.jks a partir do secret
    // APK_KEYSTORE_BASE64. Com ela, cada versão nova instala por cima da anterior.
    // Sem o arquivo (ex.: build local), usa a chave de debug.
    val chave = file("saude.jks")
    signingConfigs {
        if (chave.exists()) {
            create("saude") {
                storeFile = chave
                storePassword = "saude-apk-2026"
                keyAlias = "saude"
                keyPassword = "saude-apk-2026"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("saude") ?: signingConfigs.getByName("debug")
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
