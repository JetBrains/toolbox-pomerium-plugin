rootProject.name = "toolbox-pomerium-plugin"

val toolboxApiLocalRepo = providers.gradleProperty("toolboxApiLocalRepo")
    .orElse(providers.environmentVariable("TOOLBOX_API_LOCAL_REPO"))
    .orElse("")
    .get()
val hasLocalToolboxApiRepo = toolboxApiLocalRepo.isNotBlank() &&
    file("$toolboxApiLocalRepo/com/jetbrains/toolbox/core-api").isDirectory
val isToolboxDevInstall = gradle.startParameter.taskNames.any {
    it.substringAfterLast(':') == "installPluginForToolboxDev"
}
val useLocalToolboxApi = hasLocalToolboxApiRepo && (
    isToolboxDevInstall ||
        providers.gradleProperty("useLocalToolboxApi")
            .orElse(providers.environmentVariable("USE_LOCAL_TOOLBOX_API"))
            .map { it.equals("true", ignoreCase = true) || it in setOf("1", "yes", "on") }
            .orElse(false)
            .get()
)

include("plugin")

pluginManagement {
    includeBuild("build-logic")
    repositories {
        gradlePluginPortal()
        mavenCentral()
        maven("https://packages.jetbrains.team/maven/p/tbx/toolbox-api")
        maven("https://www.jetbrains.com/intellij-repository/snapshots")
    }
}

dependencyResolutionManagement {
    repositories {
        if (useLocalToolboxApi) {
            maven(url = uri(toolboxApiLocalRepo))
        }
        gradlePluginPortal()
        mavenCentral()
        maven("https://packages.jetbrains.team/maven/p/tbx/toolbox-api")
        maven("https://www.jetbrains.com/intellij-repository/snapshots")
    }
}
