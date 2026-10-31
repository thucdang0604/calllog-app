plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val licenseApiBaseUrl = providers.gradleProperty("LICENSE_API_BASE_URL")
    .orElse(providers.environmentVariable("LICENSE_API_BASE_URL"))
    .orElse("https://mylove-2026-sms-admin.web.app/api")
    .get()
    .trimEnd('/')
val legacyCompatibleKeystore = providers.gradleProperty("CALLLOG_RELEASE_KEYSTORE")
    .orElse("${System.getProperty("user.home")}/.android/debug.keystore")
    .get()

android {
    namespace = "com.example.call_log_manager"
    // ML Kit barcode processing compiles against API 36; min/target remain unchanged.
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.call_log_manager"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "LICENSE_API_BASE_URL", "\"$licenseApiBaseUrl\"")
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        create("releaseCompatible") {
            // Keep the existing sideloaded app updatable; changing this key breaks APK upgrades.
            storeFile = file(legacyCompatibleKeystore)
            storePassword = providers.gradleProperty("CALLLOG_RELEASE_STORE_PASSWORD").orElse("android").get()
            keyAlias = providers.gradleProperty("CALLLOG_RELEASE_KEY_ALIAS").orElse("androiddebugkey").get()
            keyPassword = providers.gradleProperty("CALLLOG_RELEASE_KEY_PASSWORD").orElse("android").get()
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("releaseCompatible")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    implementation("androidx.exifinterface:exifinterface:1.3.7")

    // CameraX for instant in-app capture without system confirmation dialog
    val cameraxVersion = "1.3.4"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")
    implementation("androidx.camera:camera-view:$cameraxVersion")
    implementation("androidx.appcompat:appcompat:1.6.1")
}

