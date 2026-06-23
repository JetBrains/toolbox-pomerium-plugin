package toolbox.plugin

import com.jetbrains.toolbox.api.core.PluginSecretStoreSuspending
import com.jetbrains.toolbox.api.core.ServiceLocator
import com.jetbrains.toolbox.api.core.auth.SSLSettings
import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.core.ui.icons.SvgIcon
import com.jetbrains.toolbox.api.core.util.LoadableState
import com.jetbrains.toolbox.api.localization.LocalizableStringFactory
import com.jetbrains.toolbox.api.remoteDev.EnvironmentId
import com.jetbrains.toolbox.api.remoteDev.ProviderVisibilityState
import com.jetbrains.toolbox.api.remoteDev.RemoteProvider
import com.jetbrains.toolbox.api.remoteDev.RemoteProviderEnvironment
import com.jetbrains.toolbox.api.remoteDev.connection.RemoteDevSessionStarter
import com.jetbrains.toolbox.api.remoteDev.connection.RemoteToolsHelper
import com.jetbrains.toolbox.api.remoteDev.states.EnvironmentStateColorPalette
import com.jetbrains.toolbox.api.remoteDev.tools.ToolHint
import com.jetbrains.toolbox.api.remoteDev.ui.EnvironmentUiPageManager
import com.jetbrains.toolbox.api.ui.ToolboxUi
import com.jetbrains.toolbox.api.ui.components.UiPage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import toolbox.auth.PomeriumAuthProvider
import toolbox.auth.PomeriumTunneler
import toolbox.auth.normalizePomeriumRoute
import toolbox.plugin.models.*
import toolbox.plugin.models.NewConnectionRequest
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import kotlin.random.Random
import kotlin.collections.listOf

enum class ConnectionVisiblePage { Login, Environment }
class PomeriumRemoteProvider(
    serviceLocator: ServiceLocator,
) : RemoteProvider("Connect through Pomerium") {
    private val scope = serviceLocator.getService(CoroutineScope::class.java)
    private val logger = serviceLocator.getService(Logger::class.java)
    private val secretStore = serviceLocator.getService(PluginSecretStoreSuspending::class.java)
    private val i18n = serviceLocator.getService(LocalizableStringFactory::class.java)
    val sslSettings = serviceLocator.getService(SSLSettings::class.java)

    private val toolboxUi = serviceLocator.getService(ToolboxUi::class.java)
    private val environmentUiPageManager = serviceLocator.getService(EnvironmentUiPageManager::class.java)
    private val starter = serviceLocator.getService(RemoteDevSessionStarter::class.java)
    private val remoteToolsHelper = serviceLocator.getService(RemoteToolsHelper::class.java)
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
    private val _envs = mutableMapOf<String, PomeriumEnvironment>()

    override val environments: MutableStateFlow<LoadableState<List<RemoteProviderEnvironment>>> =
        MutableStateFlow(LoadableState.Loading)

    init {
        environments.value = LoadableState.Loading
    }

    override fun close() {
        _envs.values.forEach(PomeriumEnvironment::close)
        _envs.clear()
        tunneler.close()
    }

    override val svgIcon: SvgIcon = SvgIcon(
        this::class.java.getResourceAsStream("/icon.svg")?.readAllBytes() ?: byteArrayOf(),
        SvgIcon.IconType.Default
    )

    override val canCreateNewEnvironments: Boolean = true
    override val isSingleEnvironment: Boolean = false

    override fun setVisible(visibilityState: ProviderVisibilityState) {}


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
        #clientPomeriumRoute=https%3A%2F%2Fbackend.localhost%3A443
        &pomeriumPort=443
        &connectionKey=https://backend.localhost:5990#
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
                "projectPath",
                "p",
                "cb",
                "connectionKey",
                "agentConnectionUrl",
                "agentAuth"
            )
        )

        val metadata = extractLinkMetadata(params)
        createEnvironmentFromRequest(
            NewConnectionRequest(
                displayName = params["displayName"].orEmpty(),
                clientPomeriumRoute = decodeUriIfNeeded(
                    params["clientPomeriumRoute"] ?: error("Missing clientPomeriumRoute")
                ),
                pomeriumInstance = params["pomeriumInstance"]?.takeIf { it.isNotBlank() },
                pomeriumPort = params["pomeriumPort"]?.toIntOrNull() ?: 443,
                projectPath = metadata.projectPath,
                productCode = metadata.productCode,
                buildNumber = metadata.buildNumber,
                agentConnectionUrl = decodeUriIfNeeded(
                    params["agentConnectionUrl"] ?: error("Missing agent connectionKey")
                ),
                agentAuth = params["agentAuth"]?.let(::decodeUriIfNeeded)?.trim()
                    ?: error("Missing agent connectionAuth"),
            )
        )
    }

    private suspend fun createEnvironmentFromRequest(request: NewConnectionRequest) {
        val clientRoute = normalizePomeriumRoute(URI(request.clientPomeriumRoute), useTls = true)
        val projectPath = request.projectPath?.takeIf { it.isNotBlank() }
        val linkIdeHint = buildIdeHint(request.productCode, request.buildNumber)
        val ideHint = linkIdeHint

        val environmentName = request.displayName
            .trim()
            .ifBlank { clientRoute.host?.takeIf { it.isNotBlank() } ?: "pomerium-${Random.nextInt(1000, 9999)}" }

        val link = PomeriumLink(
            pomeriumInstance = request.pomeriumInstance,
            pomeriumPort = request.pomeriumPort,
            projectPath = projectPath,
            ideHint = ideHint,
        )

        val pomeriumEnvironment = PomeriumEnvironment(
            environmentName,
            clientRoute.toString(),
            clientRoute.toString(),
            request.agentConnectionUrl,
            request.agentAuth,
            link,
            tunneler,
            logger,
            i18n,
            environmentStateColorPalette,
            remoteToolsHelper,
            scope,
            onDeleteRequested = { deleteEnvironment(environmentName) },
        )

        _envs[pomeriumEnvironment.id] = pomeriumEnvironment
        environments.value = LoadableState.Value(_envs.values.toList())

        environmentUiPageManager.showPluginEnvironmentsPage(false)
        toolboxUi.showWindowSuspending()
        pomeriumEnvironment.connect {
            if (!ideHint.isNullOrBlank()) {
                scope.launch {
                    starter.start(
                        EnvironmentId(pomeriumEnvironment.id),
                        ToolHint(ideHint),
                        projectPath,
                    )
                }
            }
        }
    }

    private fun buildIdeHint(productCode: String?, buildNumber: String?): String? =
        if (!productCode.isNullOrBlank() && !buildNumber.isNullOrBlank()) "$productCode-$buildNumber" else null

    private fun deleteEnvironment(environmentId: String) {
        val removed = _envs.remove(environmentId) ?: return
        logger.info("Deleting environment '$environmentId'")
        removed.close()
        environments.value = LoadableState.Value(_envs.values.toList())
    }

    private fun extractLinkMetadata(params: Map<String, String>): LinkMetadata {
        val connectionKey = params["connectionKey"]?.takeIf { it.isNotBlank() }?.let(::decodeUriIfNeeded)
        val connectionKeyDetails = connectionKey
            ?.let { runCatching { URI(it) }.getOrNull() }
            ?.fragment
            ?.let(::parseAmpParams)
            .orEmpty()

        val productCode = params["p"]?.takeIf { it.isNotBlank() }
            ?: connectionKeyDetails["p"]?.takeIf { it.isNotBlank() }
        val buildNumber = params["cb"]?.takeIf { it.isNotBlank() }
            ?: connectionKeyDetails["cb"]?.takeIf { it.isNotBlank() }
        val projectPath = params["projectPath"]?.takeIf { it.isNotBlank() }
            ?: connectionKeyDetails["projectPath"]?.takeIf { it.isNotBlank() }

        return LinkMetadata(
            productCode = productCode,
            buildNumber = buildNumber,
            projectPath = projectPath,
        )
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

private data class LinkMetadata(
    val productCode: String?,
    val buildNumber: String?,
    val projectPath: String?,
)
