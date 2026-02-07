allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
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
            
            val manifestFile = android.sourceSets.getByName("main").manifest.srcFile
            if (manifestFile.exists()) {
                val manifestContents = manifestFile.readText()
                val packageMatch = Regex("package=\"([^\"]+)\"").find(manifestContents)
                
                if (packageMatch != null) {
                    val packageName = packageMatch.groupValues[1]
                    
                    // 1. 如果没有 namespace，则注入
                    if (android.namespace == null) {
                        android.namespace = packageName
                    }
                    
                    // 2. 解决 AGP 8.0+ 不允许 Manifest 中存在 package 属性的问题
                    // 我们动态创建一个不带 package 属性的临时 Manifest，并让 Android SDK 使用它
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
