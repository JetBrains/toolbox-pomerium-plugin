import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.github.jk1.license.filter.ExcludeTransitiveDependenciesFilter
import com.github.jk1.license.render.JsonReportRenderer
import com.jetbrains.plugin.structure.toolbox.ToolboxMeta
import com.jetbrains.plugin.structure.toolbox.ToolboxPluginDescriptor
import org.gradle.kotlin.dsl.`java-library`
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.nio.file.Path
import java.io.File
import kotlin.io.path.createDirectories
import kotlin.io.path.writeText

plugins {
    alias(libs.plugins.kotlin)
    alias(libs.plugins.serialization)
    id("com.jetbrains.toolbox.packaging")
    id("com.jetbrains.toolbox.install")
    `java-library`
    `java-test-fixtures`
    alias(libs.plugins.dependency.license.report)
    alias(libs.plugins.gradle.wrapper)
    alias(libs.plugins.gettext)
    alias(libs.plugins.shadow)
}

group = "toolbox.pomerium.plugin"

val toolboxApiLocalRepo = providers.gradleProperty("toolboxApiLocalRepo")
    .orElse(providers.environmentVariable("TOOLBOX_API_LOCAL_REPO"))
    .orElse("")
    .get()
val toolboxApiLocalRepoDir = File(toolboxApiLocalRepo)
val hasLocalToolboxApiRepo = toolboxApiLocalRepo.isNotBlank() &&
    toolboxApiLocalRepoDir.resolve("com/jetbrains/toolbox/core-api").isDirectory
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
val defaultToolboxApiVersion = if (useLocalToolboxApi) "1.12.SNAPSHOT" else libs.versions.toolbox.plugin.api.get()
val toolboxApiVersion = providers.gradleProperty("toolboxApiVersionOverride")
    .orElse(providers.environmentVariable("TOOLBOX_API_VERSION_OVERRIDE"))
    .orElse(defaultToolboxApiVersion)
    .get()

// Auto-bump patch on every build invocation so Toolbox always sees a newer version after rebuild.
// Counter is persisted in .gradle/ (gitignored) and only advances when an actual build task is requested,
// not on read-only invocations like `./gradlew tasks` or IDE project sync.
val pluginBaseVersion = "1.0"
val pluginPatchFile = layout.projectDirectory.file(".gradle/plugin-patch.txt").asFile
val pluginBuildTriggers = setOf(
    "installPlugin", "installPluginForToolboxDev", "pluginZip", "build", "assemble", "shadowJar", "extensionJson", "jar"
)
val isBuildInvocation = gradle.startParameter.taskNames.any { name ->
    name.substringAfterLast(':') in pluginBuildTriggers
}
val pluginPatch: Int = run {
    val current = pluginPatchFile.takeIf { it.exists() }?.readText()?.trim()?.toIntOrNull() ?: 0
    if (!isBuildInvocation) return@run current
    val next = current + 1
    pluginPatchFile.parentFile.mkdirs()
    pluginPatchFile.writeText(next.toString())
    next
}
version = "$pluginBaseVersion.$pluginPatch"

kotlin {
    jvmToolchain(21)
}

dependencies {
    compileOnly("com.jetbrains.toolbox:core-api:$toolboxApiVersion")
    compileOnly("com.jetbrains.toolbox:ui-api:$toolboxApiVersion")
    compileOnly("com.jetbrains.toolbox:remote-dev-api:$toolboxApiVersion")
    compileOnly(libs.bundles.serialization)
    compileOnly(libs.coroutines.core)
}


repositories {
    if (useLocalToolboxApi) {
        maven {
            url = uri(toolboxApiLocalRepoDir)
        }
    }
    mavenCentral()
    maven("https://packages.jetbrains.team/maven/p/tbx/toolbox-api")
    maven("https://www.jetbrains.com/intellij-repository/releases")
}

buildscript {
    repositories {
        mavenCentral()
    }
    dependencies {
        classpath(libs.marketplace.client)
        classpath(libs.plugin.structure)
    }
}

jvmWrapper {
    unixJvmInstallDir = "jvm"
    winJvmInstallDir = "jvm"
    linuxAarch64JvmUrl = "https://cache-redirector.jetbrains.com/intellij-jbr/jbr_jcef-21.0.5-linux-aarch64-b631.28.tar.gz"
    linuxX64JvmUrl = "https://cache-redirector.jetbrains.com/intellij-jbr/jbr_jcef-21.0.5-linux-x64-b631.28.tar.gz"
    macAarch64JvmUrl = "https://cache-redirector.jetbrains.com/intellij-jbr/jbr_jcef-21.0.5-osx-aarch64-b631.28.tar.gz"
    macX64JvmUrl = "https://cache-redirector.jetbrains.com/intellij-jbr/jbr_jcef-21.0.5-osx-x64-b631.28.tar.gz"
    windowsX64JvmUrl = "https://cache-redirector.jetbrains.com/intellij-jbr/jbr_jcef-21.0.5-windows-x64-b631.28.tar.gz"
}

dependencies {
    compileOnly("com.jetbrains.toolbox:core-api:$toolboxApiVersion")
    compileOnly("com.jetbrains.toolbox:ui-api:$toolboxApiVersion")
    compileOnly("com.jetbrains.toolbox:remote-dev-api:$toolboxApiVersion")
    compileOnly(libs.bundles.serialization)
    implementation(libs.bundles.toolbox.plugin.http)
    implementation(libs.okhttp)
    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.okhttp)
    compileOnly(libs.coroutines.core)

    testImplementation(libs.junit.jupiter.api)
    testRuntimeOnly(libs.junit.jupiter.engine)
    testImplementation(libs.mockito.kotlin)
    testImplementation(libs.coroutines.test)
    testImplementation(libs.coroutines.core)
    testImplementation(libs.mockwebserver)
    testImplementation("com.jetbrains.toolbox:core-api:$toolboxApiVersion")
    testImplementation("com.jetbrains.toolbox:ui-api:$toolboxApiVersion")
    testImplementation("com.jetbrains.toolbox:remote-dev-api:$toolboxApiVersion")
    testRuntimeOnly(libs.slf4j.simple)
}

tasks.withType<Test> {
    useJUnitPlatform()
}

licenseReport {
    renderers = arrayOf(JsonReportRenderer("dependencies.json"))
    filters = arrayOf(ExcludeTransitiveDependenciesFilter())
    // jq script to convert to our format:
    // `jq '[.dependencies[] | {name: .moduleName, version: .moduleVersion, url: .moduleUrl, license: .moduleLicense, licenseUrl: .moduleLicenseUrl}]' < build/reports/dependency-license/dependencies.json > src/main/resources/dependencies.json`
}

tasks.compileKotlin {
    compilerOptions.jvmTarget.set(JvmTarget.JVM_21)
}

tasks.jar {
    archiveBaseName.set(extension.id)
    dependsOn(extensionJson)
}

tasks.shadowJar {
    archiveBaseName.set("toolbox.pomerium.plugin")
    archiveClassifier.set("")
    archiveVersion.set("")
    dependsOn(extensionJson)
    
    dependencies {
        exclude(dependency("org.jetbrains.kotlin:.*:.*"))
        exclude(dependency("org.jetbrains.kotlinx:kotlinx-coroutines-.*:.*"))
    }
}

// region will be moved to the gradle plugin late
data class ExtensionJsonMeta(
    val name: String,
    val description: String,
    val vendor: String,
    val url: String?,
)

data class ExtensionJson(
    val id: String,
    val version: String,
    val meta: ExtensionJsonMeta,
)


fun generateExtensionJson(extensionJson: ExtensionJson, destinationFile: Path) {
    val descriptor = ToolboxPluginDescriptor(
        id = extensionJson.id,
        version = extensionJson.version,
        apiVersion = toolboxApiVersion,
        meta = ToolboxMeta(
            name = extensionJson.meta.name,
            description = extensionJson.meta.description,
            vendor = extensionJson.meta.vendor,
            url = extensionJson.meta.url,
        )
    )
    val extensionJson = jacksonObjectMapper().writeValueAsString(descriptor)
    destinationFile.parent.createDirectories()
    destinationFile.writeText(extensionJson)
}

// endregion

val extension = ExtensionJson(
    id = "jetbrains.toolbox.pomerium",
    version = project.version.toString(),
    meta = ExtensionJsonMeta(
        name = "Toolbox Pomerium Plugin",
        description = "Secure Pomerium tunneler plugin for JetBrains Toolbox",
        vendor = "JetBrains",
        url = "https://www.jetbrains.com/toolbox/",
    )
)

val extensionJsonFile = layout.buildDirectory.file("generated/extension.json")
val extensionJson by tasks.registering {
    inputs.property("extension", extension.toString())

    outputs.file(extensionJsonFile)
    doLast {
        generateExtensionJson(extension, extensionJsonFile.get().asFile.toPath())
    }
}

val pluginZip by tasks.registering(Zip::class) {
    dependsOn(tasks.assemble)
    dependsOn(tasks.getByName("generateLicenseReport"))

    from(tasks.shadowJar)
    from(extensionJsonFile)
    from("src/main/resources") {
        include("dependencies.json")
    }
    from("src/main/resources") {
        include("icon.svg")
        rename("icon.svg", "pluginIcon.svg")
    }
    archiveBaseName.set("${extension.id}-${extension.version}")
}
/*


val toolboxPluginPropertiesFile = file("toolbox-plugin.properties")

val pluginMarketplaceToken: String = if (toolboxPluginPropertiesFile.exists()) {
    val token = Properties().apply { load(toolboxPluginPropertiesFile.inputStream()) }.getProperty("pluginMarketplaceToken", null)
    if (token == null) {
        error("pluginMarketplaceToken does not exist in ${toolboxPluginPropertiesFile.absolutePath}.\n" +
            "Please set pluginMarketplaceToken property to a token obtained from the marketplace.")
    }
    token
} else {
    error("toolbox-plugin.properties does not exist at ${toolboxPluginPropertiesFile.absolutePath}.\n" +
        "Please create the file and set pluginMarketplaceToken property to a token obtained from the marketplace.")
}

println("Plugin Marketplace Token: ${pluginMarketplaceToken.take(5)}*****")


// Work in progress. The public version of Marketplace will not accept the plugin yet
val uploadPlugin by tasks.registering {
    dependsOn(pluginZip)

    doLast {
        val instance = PluginRepositoryFactory.
        create(
            "https://plugins.jetbrains.com",
            pluginMarketplaceToken
        )

        // first upload
//        instance.uploader.uploadNewPlugin(
//            pluginZip.get().outputs.files.singleFile,
//            listOf("toolbox", "gateway"),
//            LicenseUrl.APACHE_2_0,
//            ProductFamily.TOOLBOX,
//            extension.meta.vendor,
//            isHidden = true
//        )

        // subsequent updates
//        instance.uploader.uploadUpdateByXmlIdAndFamily(
//            extension.id,
//            ProductFamily.TOOLBOX,
//            pluginZip.get().outputs.files.singleFile,
//        )
    }
}
*/

// Known issue with kotlin 2.1.0 when using MutableStateFlow, please remove
// once https://youtrack.jetbrains.com/issue/KT-73951 is released and you upgrade version.
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile> {
    compilerOptions {
        freeCompilerArgs.add("-Xdisable-phases=ConstEvaluationLowering")
        freeCompilerArgs.add("-Xskip-metadata-version-check")
    }
}
gettext {
    potFile = project.layout.projectDirectory.file("src/main/resources/localization/defaultMessages.pot")
    keywords = listOf("ptrc:1c,2", "ptrl")
}
