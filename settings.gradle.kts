rootProject.name = "toolbox-pomerium-plugin"

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
        gradlePluginPortal()
        mavenCentral()
        maven("https://packages.jetbrains.team/maven/p/tbx/toolbox-api")
        maven("https://www.jetbrains.com/intellij-repository/snapshots")
    }
}
