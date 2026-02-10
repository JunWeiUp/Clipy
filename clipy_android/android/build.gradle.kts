import java.io.File
import org.gradle.api.plugins.ExtensionAware

allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
    }
}

subprojects {
    // 只为插件项目（非 app 项目）提供默认的 flutter 属性，解决 "unknown property 'flutter'" 错误
    if (project.name != "app") {
        project.ext.set("flutter", mapOf(
            "compileSdkVersion" to 34,
            "minSdkVersion" to 21,
            "targetSdkVersion" to 34,
            "ndkVersion" to "25.1.8937393"
        ))
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    afterEvaluate {
        if (project.extensions.findByName("android") != null) {
            val android = project.extensions.getByName("android") as com.android.build.gradle.BaseExtension
            
            // 为 android 扩展注入 flutter 属性，满足旧插件的需求
            if ((android as? ExtensionAware)?.extensions?.findByName("flutter") == null) {
                (android as? ExtensionAware)?.extensions?.add("flutter", mapOf(
                    "compileSdkVersion" to 34,
                    "minSdkVersion" to 21,
                    "targetSdkVersion" to 34,
                    "ndkVersion" to "25.1.8937393"
                ))
            }

            // 1. 强制设置 compileSdkVersion，解决插件未指定 compileSdk 的问题
            if (android.compileSdkVersion == null) {
                android.compileSdkVersion("android-34")
            }

            val manifestFile = android.sourceSets.getByName("main").manifest.srcFile
            if (manifestFile.exists()) {
                val manifestContents = manifestFile.readText()
                val packageMatch = Regex("package=\"([^\"]+)\"").find(manifestContents)
                
                if (packageMatch != null) {
                    val packageName = packageMatch.groupValues[1]
                    
                    // 2. 如果没有 namespace，则注入
                    if (android.namespace == null) {
                        android.namespace = packageName
                    }
                    
                    // 3. 解决 AGP 8.0+ 不允许 Manifest 中存在 package 属性的问题
                    val tempDir = File(project.layout.buildDirectory.get().asFile, "intermediates/fixed_manifests/${project.name}")
                    if (!tempDir.exists()) tempDir.mkdirs()
                    
                    val fixedManifest = File(tempDir, "AndroidManifest.xml")
                    val cleanContent = manifestContents.replace(Regex("package=\"[^\"]+\""), "")
                    fixedManifest.writeText(cleanContent)
                    
                    android.sourceSets.getByName("main").manifest.srcFile(fixedManifest)
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
