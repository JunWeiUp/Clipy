import java.util.Properties
import java.io.File

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}
val sourceVersion = Regex("(?m)^version: ([0-9.]+)\\+([0-9]+)$")
    .find(rootProject.file("../clipy_flutter/pubspec.yaml").readText())
    ?: error("Missing source version")
val nativeProduction = providers.gradleProperty("nativeProduction").orNull == "true"
val nativeAbi = providers.gradleProperty("nativeAbi").orNull
require(nativeAbi == null || nativeAbi in setOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86")) { "Unsupported nativeAbi" }
val nativeAbis = providers.gradleProperty("nativeAbis").orNull?.split(",")
require(nativeAbi == null || nativeAbis == null) { "Use either nativeAbi or nativeAbis" }
require(nativeAbis == null || (nativeAbis.isNotEmpty() && nativeAbis.all { it in setOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86") })) { "Unsupported nativeAbis" }
val appVersion = System.getenv("APP_VERSION")?.takeIf { it.isNotBlank() } ?: sourceVersion.groupValues[1]
val buildNumber = (System.getenv("BUILD_NUMBER")?.takeIf { it.isNotBlank() } ?: sourceVersion.groupValues[2]).toLongOrNull()
    ?: error("BUILD_NUMBER must be an integer")
require(Regex("[0-9]+\\.[0-9]+\\.[0-9]+").matches(appVersion)) { "APP_VERSION must be X.Y.Z" }
require(buildNumber in 1..2100000000L) { "BUILD_NUMBER is out of range" }
val originalAndroidRoot = rootProject.file("../clipy_flutter/android")
val releaseProperties = Properties().apply {
    val source = originalAndroidRoot.resolve("key.properties")
    if (source.exists()) source.inputStream().use { load(it) }
}
fun signingValue(property: String, environment: String): String? =
    System.getenv(environment)?.takeIf { it.isNotBlank() } ?: releaseProperties.getProperty(property)?.takeIf { it.isNotBlank() }
val releaseStorePath = signingValue("storeFile", "CLIPY_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "CLIPY_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "CLIPY_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "CLIPY_KEY_PASSWORD")
val signingValues = listOf(releaseStorePath, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
val hasReleaseSigning = signingValues.all { it != null }
require(signingValues.all { it == null } || hasReleaseSigning) { "Incomplete release signing configuration" }

android {
    namespace = "com.clipyclone.nativeandroid"
    compileSdk = 36
    defaultConfig {
        // Isolated preview: never replace the shipping app before parity gates pass.
        applicationId = if (nativeProduction) "com.clipyclone.clipy_android" else "com.clipyclone.clipy_android.nativepreview"
        minSdk = 26
        targetSdk = 36
        versionCode = buildNumber.toInt()
        versionName = appVersion + if (nativeProduction) "" else "-native-preview"
        manifestPlaceholders["nativeAppLabel"] = if (nativeProduction) "Clipy Android" else "@string/app_name"
        // Preserve the installed app's system-backup eligibility; isolated fixtures never back up.
        manifestPlaceholders["nativeAllowBackup"] = nativeProduction
        nativeAbi?.let { ndk.abiFilters.add(it) }
        nativeAbis?.let { ndk.abiFilters.addAll(it) }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
    signingConfigs {
        if (hasReleaseSigning) create("release") {
            val configuredPath = requireNotNull(releaseStorePath)
            val source = File(configuredPath)
            storeFile = if (source.isAbsolute) source else originalAndroidRoot.resolve(configuredPath)
            storePassword = releaseStorePassword; keyAlias = releaseKeyAlias; keyPassword = releaseKeyPassword
        }
    }
    buildTypes {
        release {
            // Keep the SDK's reflection/JNA ABI unchanged; release smoke tests still verify native crypto.
            isMinifyEnabled = false
            signingConfig = if (nativeProduction && hasReleaseSigning) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }
}
gradle.taskGraph.whenReady {
    if (nativeProduction && allTasks.any { it.project == project && it.name in setOf("assembleRelease", "bundleRelease", "packageRelease") } && !hasReleaseSigning) {
        throw GradleException("Production native builds require the existing release signing identity; no ad-hoc fallback.")
    }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    implementation("com.github.JunWeiUp.common-relay:java:v0.1.3")
    implementation("com.google.zxing:core:3.5.3")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    implementation("com.goterl:lazysodium-android:5.2.0@aar")
    implementation("com.google.crypto.tink:tink-android:1.19.0")
    implementation("androidx.work:work-runtime-ktx:2.9.0")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.compose.material3:material3:1.4.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
