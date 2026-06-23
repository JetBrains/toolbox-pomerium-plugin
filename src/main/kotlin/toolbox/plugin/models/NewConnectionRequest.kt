package toolbox.plugin.models

data class NewConnectionRequest(
    val displayName: String,
    val clientPomeriumRoute: String,
    val pomeriumInstance: String?,
    val pomeriumPort: Int,
    val projectPath: String?,
    val productCode: String?,
    val buildNumber: String?,
    val agentConnectionUrl: String,
    val agentAuth: String,
)