package toolbox.plugin

import com.jetbrains.toolbox.api.core.PluginSecretStoreSuspending
import com.jetbrains.toolbox.api.core.ServiceLocator
import com.jetbrains.toolbox.api.core.auth.SSLSettings
import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.core.ui.icons.SvgIcon
import com.jetbrains.toolbox.api.core.util.LoadableState
import com.jetbrains.toolbox.api.localization.LocalizableStringFactory
import com.jetbrains.toolbox.api.remoteDev.ProviderVisibilityState
import com.jetbrains.toolbox.api.remoteDev.RemoteProvider
import com.jetbrains.toolbox.api.remoteDev.RemoteProviderEnvironment
import com.jetbrains.toolbox.api.remoteDev.connection.ClientHelper
import com.jetbrains.toolbox.api.remoteDev.states.EnvironmentStateColorPalette
import com.jetbrains.toolbox.api.remoteDev.ui.EnvironmentUiPageManager
import com.jetbrains.toolbox.api.ui.ToolboxUi
import com.jetbrains.toolbox.api.ui.components.UiPage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import toolbox.auth.PomeriumAuthProvider
import toolbox.auth.PomeriumTunneler
import toolbox.plugin.models.*
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

enum class ConnectionVisiblePage { Login, Environment }
class PomeriumRemoteProvider(
    serviceLocator: ServiceLocator,
) : RemoteProvider("Connect through Pomerium") {
    private val scope = serviceLocator.getService(CoroutineScope::class.java)
    private val logger = serviceLocator.getService(Logger::class.java)
    private val secretStore = serviceLocator.getService(PluginSecretStoreSuspending::class.java)
    private val i18n = serviceLocator.getService(LocalizableStringFactory::class.java)
    val sslSettings = serviceLocator.getService(SSLSettings::class.java)

    private val pluginScope = serviceLocator.getService(CoroutineScope::class.java)
    private val toolboxUi = serviceLocator.getService(ToolboxUi::class.java)
    private val environmentUiPageManager = serviceLocator.getService(EnvironmentUiPageManager::class.java)
    private val clientHelper = serviceLocator.getService(ClientHelper::class.java)
    private val environmentStateColorPalette = serviceLocator.getService(EnvironmentStateColorPalette::class.java)

    private val pomeriumPort = 443
    val PomeriumAuthService by lazy {
        PomeriumAuthProvider(
            secretStore,
            pomeriumPort = pomeriumPort,
            sslSettings = sslSettings,
        )
    }
    private val tunneler = PomeriumTunneler(
        PomeriumAuthService,
        logger,
        trustManager = sslSettings.getTrustManager(),
    )
    private val _envs = mutableMapOf<String, RemoteProviderEnvironment>()

    override val environments: MutableStateFlow<LoadableState<List<RemoteProviderEnvironment>>> =
        MutableStateFlow(LoadableState.Loading)

    init {
        environments.value = LoadableState.Loading
    }

    override fun close() {
        tunneler.close()
    }

    override val svgIcon: SvgIcon = SvgIcon(
        this::class.java.getResourceAsStream("/icon.svg")?.readAllBytes() ?: byteArrayOf(),
        SvgIcon.IconType.Default
    )

    override val canCreateNewEnvironments: Boolean = false
    override val isSingleEnvironment: Boolean = false

    override fun setVisible(visibilityState: ProviderVisibilityState) {}

    override fun getNewEnvironmentUiPage(): UiPage? {
        return null//NewConnectionPage(tunneler, i18n, i18n.ptrl("New connection"))
    }

    private val state = ConnectionState()
    private val visiblePage = state.authState.combine(state.agentState, { authState, agentState ->
        if (authState == AuthState.LoggedOut || agentState == AgentState.NotAvailable) {
            return@combine ConnectionVisiblePage.Login
        }
        return@combine ConnectionVisiblePage.Environment
    }).stateIn(scope, SharingStarted.Eagerly, ConnectionVisiblePage.Login)

    override fun getOverrideUiPage(): UiPage? {
        return null
    }

    override suspend fun handleUri(uri: URI) {
        /*
        jetbrains://remote-dev/jetbrains.toolbox.pomerium/new-environment
        #clientPomeriumRoute=tcp%3A%2F%2Fbackend.localhost%3A443
        &pomeriumPort=443
        &connectionKey=tcp://127.0.0.1:61618#
                jt=f91eab64-f2d2-4f37-b9b0-7562bdacf07b
                &p=IU&fp=3BC0F51FB06705BA5B7A3B379B2D064DB8ADB3AC30026DED36EA50CA51BE6C12
                &cb=253.32098.37
                &newUi=true
                &jb=21.0.10b1163.110
                &remoteId=
        &agentConnectionUrl=https%3A%2F%2Flocalhost%3A44000
        &agentAuth=319999dd35457fc53be9235929ee5ea2
*/
        logger.info("Handling new url: $uri")
        val paramSource = when {
            !uri.rawFragment.isNullOrBlank() -> uri.rawFragment
            !uri.rawQuery.isNullOrBlank() -> uri.rawQuery
            else -> error("No parameters in URL fragment/query: $uri")
        }

        val params = parseTopLevelParams(
            paramSource!!,
            listOf(
                "clientPomeriumRoute",
                "displayName",
                "pomeriumInstance",
                "pomeriumPort",
                "connectionKey",
                "agentConnectionUrl",
                "agentAuth"
            )
        )

        val rawRoute = decodeUriIfNeeded(params["clientPomeriumRoute"] ?: error("Missing clientPomeriumRoute"))

        val clientRoute = URI(rawRoute.toString())

        val pomeriumInstance = params["pomeriumInstance"]?.takeIf { it.isNotBlank() }
        val pomeriumPort = params["pomeriumPort"]?.toIntOrNull() ?: 443
        val name = params["displayName"].toString()

        val connectionLink = decodeUriIfNeeded(params["connectionKey"] ?: error("Missing connectionKey"))
        val connectionKeyUri = URI(connectionLink)
        val connectionKeyDetails = parseAmpParams(connectionKeyUri.fragment ?: "")
        val jt = connectionKeyDetails["jt"]
        val p = connectionKeyDetails["p"]
        val fp = connectionKeyDetails["fp"]
        val cb = connectionKeyDetails["cb"]
        val newUi = connectionKeyDetails["newUi"]
        val jb = connectionKeyDetails["jb"]
        val remoteId = connectionKeyDetails["remoteId"]

        val endpoint = connectionLink.toString().substringBefore('#')

        val remotePort = runCatching { URI(endpoint).port }.getOrNull()?.takeIf { it >= 0 }
        val agentConnectionUrl = decodeUriIfNeeded(params["agentConnectionUrl"] ?: error("Missing agent connectionKey"))
        val agentConnectionAuth = params["agentAuth"]?.trim() ?: error("Missing agent connectionAuth")

        val link = PomeriumLink(
            pomeriumInstance = pomeriumInstance,
            pomeriumPort = pomeriumPort
        )

        val pomeriumEnvironment = PomeriumEnvironment(
            name,
            clientRoute.toString(),
            connectionLink.toString(),
            agentConnectionUrl.toString(),
            agentConnectionAuth.toString(),
            link,
            tunneler,
            logger,
            i18n,
            environmentStateColorPalette,
            scope
        )

        _envs[name] = pomeriumEnvironment
        environments.value = LoadableState.Value(_envs.values.toList())

        environmentUiPageManager.showPluginEnvironmentsPage(true)
        toolboxUi.showWindowSuspending()
        pomeriumEnvironment.connect {
            if (!connectionLink.isNullOrBlank())
                if (!p.isNullOrBlank() && !cb.isNullOrBlank()) {
                    clientHelper.connectToIde(pomeriumEnvironment.id, "$p-$cb", null)
                }
        }
    }

    private fun parseTopLevelParams(source: String, keys: List<String>): Map<String, String> {
        val markers = keys.mapNotNull { key ->
            source.indexOf("$key=").takeIf { it >= 0 }?.let { idx -> idx to key }
        }.sortedBy { it.first }

        val result = mutableMapOf<String, String>()
        markers.forEachIndexed { idx, (startIdx, key) ->
            val valueStart = startIdx + key.length + 1
            val nextStart = markers.getOrNull(idx + 1)?.first ?: source.length
            val valueEnd = if (nextStart > 0 && source[nextStart - 1] == '&') nextStart - 1 else nextStart
            val rawValue = source.substring(valueStart, valueEnd)
            result[key] = decodePreservingPlus(rawValue)
        }
        return result
    }

    private fun parseAmpParams(source: String): Map<String, String> {
        if (source.isBlank()) return emptyMap()
        return source.split("&")
            .filter { it.isNotBlank() }
            .associate { part ->
                val kv = part.split("=", limit = 2)
                val key = decodePreservingPlus(kv[0])
                val value = decodePreservingPlus(kv.getOrElse(1) { "" })
                key to value
            }
    }

    private fun decodePreservingPlus(value: String): String =
        URLDecoder.decode(value.replace("+", "%2B"), StandardCharsets.UTF_8)

    private fun decodeUriIfNeeded(value: String): String {
        return decodePreservingPlus(value)
    }
}
