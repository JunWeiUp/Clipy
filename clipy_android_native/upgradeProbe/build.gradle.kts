plugins { id("com.android.application") }

// A separate, non-launchable inspection APK. It never replaces the installed app.
evaluationDependsOn(":app")
val original = project(":app").extensions
    .getByType(com.android.build.api.dsl.ApplicationExtension::class.java)
    .signingConfigs.findByName("release")
android {
    namespace = "com.clipyclone.upgradeprobe"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.clipyclone.clipy_android.upgradeprobe"
        // The inspection tool uses SQLite VACUUM INTO; the actual app remains API 24+.
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "1"
    }
    signingConfigs {
        if (original != null) create("original") {
            storeFile = original.storeFile
            storePassword = original.storePassword
            keyAlias = original.keyAlias
            keyPassword = original.keyPassword
        }
    }
    buildTypes { release { signingConfig = signingConfigs.findByName("original") } }
}
gradle.taskGraph.whenReady {
    if (allTasks.any { it.project == project && it.name in setOf("assembleRelease", "packageRelease") }) {
        check(original != null) { "Upgrade inspection requires the installed application's original signing identity" }
    }
}
