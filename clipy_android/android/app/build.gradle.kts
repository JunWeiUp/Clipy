import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Local key.properties or CI environment variables; credentials never belong in Git.
val releaseProperties = Properties().apply {
    val propertiesFile = rootProject.file("key.properties")
    if (propertiesFile.exists()) propertiesFile.inputStream().use { load(it) }
}
fun signingValue(property: String, environment: String): String? =
    System.getenv(environment)?.takeIf { it.isNotBlank() }
        ?: releaseProperties.getProperty(property)?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingValue("storeFile", "CLIPY_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "CLIPY_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "CLIPY_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "CLIPY_KEY_PASSWORD")
val signingValues = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
val hasReleaseSigning = signingValues.all { it != null }
val allowDebugSigning = System.getenv("CLIPY_ALLOW_DEBUG_SIGNING") == "1"
require(signingValues.all { it == null } || hasReleaseSigning) {
    "Incomplete release signing configuration. See docs/DEVELOPMENT.md."
}

android {
    namespace = "com.clipyclone.clipy_android"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Keep stable for upgrades and the native method-channel contract.
        applicationId = "com.clipyclone.clipy_android"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else if (allowDebugSigning) {
                // Explicitly opted-in local smoke build; never use for distribution.
                signingConfig = signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

gradle.taskGraph.whenReady {
    val packagesRelease = allTasks.any {
        it.project == project && it.name in setOf("assembleRelease", "bundleRelease", "packageRelease")
    }
    if (packagesRelease && !hasReleaseSigning && !allowDebugSigning) {
        throw GradleException("Release signing is required. See docs/DEVELOPMENT.md; for local tests only, set CLIPY_ALLOW_DEBUG_SIGNING=1.")
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.19.0")
    // WorkManager: periodic self-healing watchdog that re-asserts the sync FGS
    // after the system (Doze / MIUI killer / dataSync 6h quota on Android 15)
    // stops or kills it. Doze-friendly: periodic work is always rescheduled by
    // the system even if START_STICKY delivery is dropped.
    implementation("androidx.work:work-runtime-ktx:2.9.0")
}
