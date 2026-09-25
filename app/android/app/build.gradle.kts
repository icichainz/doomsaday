plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.doomsaday.doomsaday"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // The free flavor keeps this id, so an existing install keeps its data.
        applicationId = "dev.doomsaday.doomsaday"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The two editions of design/README.md. Free keeps the original id; Pro is
    // the same app with a .pro suffix, so both install side by side.
    flavorDimensions += "edition"

    productFlavors {
        create("free") {
            dimension = "edition"
            resValue("string", "app_name", "Doomsaday")
        }
        create("pro") {
            dimension = "edition"
            applicationIdSuffix = ".pro"
            resValue("string", "app_name", "Doomsaday Pro")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
