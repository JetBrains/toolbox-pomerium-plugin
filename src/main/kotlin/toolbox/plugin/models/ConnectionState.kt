package toolbox.plugin.models

import kotlinx.coroutines.flow.MutableStateFlow
import java.net.URI



data class DevEnvConnectionInfo (
    val url: String,
    val agentRelayUrl: String,
    val agentRelayAuthData: String? = null,
    val pomeriumPort: Int = 443,
)

data class PomeriumLink(
    val pomeriumInstance: String?,
    val pomeriumPort: Int
)
enum class AuthState {
    LoggedOut,
    LoggedIn
}
enum class AgentState {
    Available,
    NotAvailable
}
class ConnectionState {
    var authState: MutableStateFlow<AuthState> = MutableStateFlow(AuthState.LoggedOut)
    var agentState: MutableStateFlow<AgentState> = MutableStateFlow(AgentState.NotAvailable)
}
