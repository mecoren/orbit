allprojects {
    repositories {
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
// AGP 9 硬性要求 library 模块声明 namespace；存量停更插件（如
// flutter_app_badger 1.5.0，2022 年停更）只有 AndroidManifest package 属性。
// 迁移期官方方案：配置期从其 manifest 读 package 回填 namespace——
// 不改第三方包缓存（干净机器可复现）。
subprojects {
    pluginManager.withPlugin("com.android.library") {
        if (extensions.findByName("android") == null) return@withPlugin
        val androidExt = extensions.findByName("android")
        val nsGetter = androidExt?.javaClass?.getMethod("getNamespace")
        val currentNs = try {
            nsGetter?.invoke(androidExt) as? String
        } catch (_: Exception) {
            null
        }
        if (currentNs.isNullOrBlank()) {
            val manifestNs = project.file("src/main/AndroidManifest.xml")
                .takeIf { it.exists() }
                ?.readText()
                ?.let { raw ->
                    Regex("package=\"([^\"]+)\"").find(raw)?.groupValues?.get(1)
                }
            if (manifestNs != null) {
                val nsSetter = androidExt?.javaClass?.getMethod("setNamespace", String::class.java)
                nsSetter?.invoke(androidExt, manifestNs)
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
