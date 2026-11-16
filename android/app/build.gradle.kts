import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The installed app's identity. A neutral name that matches the cover (a
// video trimmer) and not the project, so the package doesn't lead to it.
// An organisation can build with its own: -PappId=... (or the environment
// variable ORG_GRADLE_PROJECT_appId).
//
// The old package, for an update that lets earlier installs move their
// vault out (signed with the old development key):
//   ORG_GRADLE_PROJECT_appId=com.example.gesture_unlock ORG_GRADLE_PROJECT_legacySigning=true flutter build apk --release
val appId = (project.findProperty("appId") as String?) ?: "com.videotrimmer.local"
val legacySigning = (project.findProperty("legacySigning") as String?) == "true"

// The permanent release key: android/key.properties (never committed; see
// docs/RELEASING.md). Without it, release builds use the debug key.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.example.gesture_unlock"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        if (keyProps.containsKey("storeFile")) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        applicationId = appId
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = if (!legacySigning && keyProps.containsKey("storeFile")) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
