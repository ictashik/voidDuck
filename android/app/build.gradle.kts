plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.voidduck.voidduck"
    compileSdk = flutter.compileSdkVersion
    // Pinned per flutter_gemma's own example app — the LiteRT-LM native
    // build requires this NDK line; flutter.ndkVersion alone isn't
    // guaranteed to match.
    ndkVersion = "28.2.13676358"

    // Keep the bundled .litertlm model as a single flat, byte-addressable
    // file inside the APK. Without this AAPT deflate-compresses it, and the
    // LiteRT-LM runtime needs to mmap the asset directly — a compressed
    // asset can't be mapped and either fails to load or gets fully
    // decompressed into memory (doubling RAM for a multi-GB model).
    aaptOptions {
        noCompress("litertlm", "task", "tflite", "bin")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.voidduck.voidduck"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Confirmed via on-device A/B test: the release dex is ~4x smaller
            // than debug's (R8 shrinking is active by default here despite no
            // explicit opt-in), and google_mlkit_face_detection's continuous
            // "ImageError: Getting Image failed" NPE — reproduced on every
            // release build, never on debug — disappears when shrinking is
            // off. This is a sideloaded personal app with no distribution
            // surface to protect, so there's nothing shrinking buys us that's
            // worth a live camera pipeline breaking on-device.
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

dependencies {
    // Gesture (Open_Palm) trigger (spec Section 4.2.3): hand-rolled native
    // bridge around Google's official Gesture Recognizer task, rather than
    // an unverified third-party Flutter wrapper, since this touches the
    // live camera feed on a privacy-critical pipeline.
    implementation("com.google.mediapipe:tasks-vision:1.0.0")
}

flutter {
    source = "../.."
}
