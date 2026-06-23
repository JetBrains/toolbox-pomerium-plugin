package toolbox.plugin.models

import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.localization.LocalizableStringFactory
import com.jetbrains.toolbox.api.remoteDev.*
import com.jetbrains.toolbox.api.remoteDev.TabDefinition.Companion.projectsTab
import com.jetbrains.toolbox.api.remoteDev.TabDefinition.Companion.toolsTab
import com.jetbrains.toolbox.api.remoteDev.connection.RemoteToolsHelper
import com.jetbrains.toolbox.api.remoteDev.environments.CachedIdeStub
import com.jetbrains.toolbox.api.remoteDev.environments.CachedProject
import com.jetbrains.toolbox.api.remoteDev.environments.EnvironmentContentsView
import com.jetbrains.toolbox.api.remoteDev.states.*
import com.jetbrains.toolbox.api.ui.actions.ActionDescription
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import toolbox.auth.PomeriumTunnelState
import toolbox.auth.PomeriumTunneler
import toolbox.plugin.PomeriumEnvironmentContentsView
import java.io.Closeable
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

private data class ConnectionLease(
    val kind: String,
    val route: URI,
)

sealed interface EnvironmentState {
    data object Disconnected : EnvironmentState
    data object Connecting : EnvironmentState
    data object Connected : EnvironmentState
    data object WaitingForAuthorization : EnvironmentState
    data object RefreshingAuthorization : EnvironmentState
    data object UpstreamNotReady : EnvironmentState
    data object Reconnecting : EnvironmentState
    data object AgentUnavailable : EnvironmentState
    data object AgentConnectionError : EnvironmentState
    data object AgentAuthorizationError : EnvironmentState
    data object PomeriumUnavailable : EnvironmentState
    data object PomeriumAuthorizationError : EnvironmentState
    data object PomeriumTunnelCreationError : EnvironmentState
}

fun PomeriumTunnelState.toEnvironmentState(): EnvironmentState = when (this) {
    PomeriumTunnelState.WaitingForAuthorization -> EnvironmentState.WaitingForAuthorization
    PomeriumTunnelState.Connecting -> EnvironmentState.Connecting
    PomeriumTunnelState.Connected -> EnvironmentState.Connected
    PomeriumTunnelState.RefreshingAuthorization -> EnvironmentState.RefreshingAuthorization
    PomeriumTunnelState.Reconnecting -> EnvironmentState.Reconnecting
    PomeriumTunnelState.UpstreamNotReady -> EnvironmentState.UpstreamNotReady
    PomeriumTunnelState.PomeriumUnavailable -> EnvironmentState.PomeriumUnavailable
    PomeriumTunnelState.PomeriumAuthorizationError -> EnvironmentState.PomeriumAuthorizationError
    PomeriumTunnelState.PomeriumTunnelCreationError -> EnvironmentState.PomeriumTunnelCreationError
}

class PomeriumEnvironment(
    private val displayName: String,
    val url: String,
    clientRoute: String,
    val agentUrl: String,
    val agentAuthData: String?,
    val link: PomeriumLink,
    private val tunneler: PomeriumTunneler,
    private val logger: Logger,
    i18n: LocalizableStringFactory,
    colorPalette: EnvironmentStateColorPalette,
    remoteToolsHelper: RemoteToolsHelper,
    pluginScope: CoroutineScope,
    private val onDeleteRequested: () -> Unit,
) : RemoteProviderEnvironment(displayName), Closeable {
    private val activeConnectionLeases = ConcurrentHashMap<String, ConnectionLease>()

    // Owns per-environment lifetime. Cancelling this cancels every in-flight auth job
    // and any other coroutine launched from this environment (handles, contents view).
    // Child of pluginScope so plugin shutdown also tears this down.
    private val environmentScope: CoroutineScope = CoroutineScope(
        SupervisorJob(pluginScope.coroutineContext[Job]) + Dispatchers.Default
    )

    init {
        logger.info("Initializing pomerium environment")
        logger.info("Environment name: $displayName")
        logger.info("Environment '${id}': initial state ${EnvironmentState.Disconnected::class.simpleName}")
    }

    override val description: MutableStateFlow<EnvironmentDescription> =
        MutableStateFlow(EnvironmentDescription.General(null))
    override val connectionRequest: MutableSharedFlow<Boolean> = MutableSharedFlow(replay = 1)
    val environmentState: MutableStateFlow<EnvironmentState> = MutableStateFlow(EnvironmentState.Disconnected)
    override val nameFlow: MutableStateFlow<String>
        get() = MutableStateFlow(displayName)
    private val contentsView = PomeriumEnvironmentContentsView(
        environmentScope,
        logger,
        this,
        tunneler,
        remoteToolsHelper,
        ::handleBeforeProjectOpen,
        DevEnvConnectionInfo(
            this.url,
            this.agentUrl,
            this.agentAuthData,
            this.link.pomeriumPort,
        )
    )

    private fun handleBeforeProjectOpen() {

    }

    override fun getAfterDisconnectHooks(): List<AfterDisconnectHook> {
        return emptyList()
    }

    suspend fun connect(afterConnection: () -> Unit) {
        // setEnvironmentState(EnvironmentState.Connecting)
        setEnvironmentState(EnvironmentState.Connected)
        connectionRequest.emit(true)
        afterConnection()
    }

    suspend fun disconnect() {
        // Cancel any in-flight auth / tunnel jobs that were launched into the environment scope.
        // children() avoids cancelling environmentScope itself, so reconnect from the same env still works.
        environmentScope.coroutineContext[Job]?.children?.forEach { it.cancel() }
        activeConnectionLeases.clear()
        setEnvironmentState(EnvironmentState.Disconnected)
        connectionRequest.emit(false)
    }

    override suspend fun getContentsView(): EnvironmentContentsView = contentsView

    override fun setVisible(visibilityState: EnvironmentVisibilityState) {}

    override val supportedFeatures =
        setOf(RemoteEnvironmentAbility.CAN_RENAME, RemoteEnvironmentAbility.ALWAYS_CONNECTED)

    override val actionsList: StateFlow<List<ActionDescription>> = MutableStateFlow(emptyList())

    override val availableSettingsSections: Set<SettingsSection>
        get() = setOf(
            SettingsSection.ABOUT_ENVIRONMENT, SettingsSection.TOOLS
        )
    override val pageTabs: List<TabDefinition> =
        if (link.projectPath.isNullOrBlank()) listOf(toolsTab()) else listOf(projectsTab(), toolsTab())
    override val state: StateFlow<RemoteEnvironmentState> =
        environmentState.map { envState ->
            when (envState) {
                EnvironmentState.Disconnected -> StandardRemoteEnvironmentState.Inactive
                EnvironmentState.Connecting -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Waiting for connection"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Initializing),
                    true,
                    EnvironmentStateIcons.Connecting,
                )

                EnvironmentState.Connected -> StandardRemoteEnvironmentState.Active
                EnvironmentState.WaitingForAuthorization -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Waiting for authorization"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Initializing),
                    true,
                    EnvironmentStateIcons.Connecting,
                )

                EnvironmentState.RefreshingAuthorization -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Refreshing authorization"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Initializing),
                    true,
                    EnvironmentStateIcons.Connecting,
                )

                EnvironmentState.UpstreamNotReady -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Waiting for upstream"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Initializing),
                    true,
                    EnvironmentStateIcons.Connecting,
                )

                EnvironmentState.Reconnecting -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Reconnecting"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Initializing),
                    true,
                    EnvironmentStateIcons.Connecting,
                )

                EnvironmentState.AgentUnavailable -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Toolbox Agent is unavailable"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Unreachable),
                    false,
                    EnvironmentStateIcons.Offline,
                )

                EnvironmentState.AgentConnectionError -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Connection to remote end failed"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Error),
                    false,
                    EnvironmentStateIcons.Error,
                )

                EnvironmentState.AgentAuthorizationError -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Authorization failed"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Failed),
                    false,
                    EnvironmentStateIcons.Error,
                )

                EnvironmentState.PomeriumUnavailable -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Pomerium is unavailable"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Unreachable),
                    true,
                    EnvironmentStateIcons.Offline,
                )

                EnvironmentState.PomeriumAuthorizationError -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Authorization failed"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Failed),
                    true,
                    EnvironmentStateIcons.Error,
                )

                EnvironmentState.PomeriumTunnelCreationError -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Pomerium tunnel creation failed"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Error),
                    false,
                    EnvironmentStateIcons.Error,
                )
            }
        }.stateIn(pluginScope, SharingStarted.Eagerly, StandardRemoteEnvironmentState.Inactive)

    fun setEnvironmentState(newState: EnvironmentState) {
        val previousState = environmentState.value
        logger.info("Environment '$id': ${previousState::class.simpleName} -> ${newState::class.simpleName}")
        environmentState.value = newState
        if (newState == EnvironmentState.Connected && previousState != EnvironmentState.Connected) {
            contentsView.refreshInstalledIdeListAsync()
        }
    }

    fun registerConnectionLease(leaseId: String, kind: String, route: URI) {
        val lease = ConnectionLease(kind, route)
        if (activeConnectionLeases.putIfAbsent(leaseId, lease) == null) {
            logger.info(
                "Environment '$id': registered $kind lease '$leaseId' for $route, activeLeases=${activeConnectionLeases.size}"
            )
        }
    }

    fun releaseConnectionLease(leaseId: String, kind: String, route: URI) {
        if (activeConnectionLeases.remove(leaseId) == null) {
            logger.debug("Environment '$id': lease '$leaseId' already released for $kind route $route")
            return
        }

        val remaining = activeConnectionLeases.size
        logger.info(
            "Environment '$id': released $kind lease '$leaseId' for $route, activeLeases=$remaining"
        )
        if (remaining == 0) {
            setEnvironmentState(EnvironmentState.Disconnected)
        } else {
            logger.info("Environment '$id': keeping state because $remaining lease(s) are still active")
        }
    }

    @Deprecated("Use deleteActionFlow instead", ReplaceWith("deleteActionFlow"))
    override fun onDelete() {
        logger.info("Environment '$id': delete requested")
        close()
        onDeleteRequested()
    }

    override fun close() {
        val activeLeases = activeConnectionLeases.values.toList()
        activeConnectionLeases.clear()
        activeLeases.forEach { lease ->
            runCatching { tunneler.closeTunnel(lease.route) }
                .onFailure { error ->
                    logger.warn("Environment '$id': failed to close ${lease.kind} tunnel for ${lease.route}: ${error.message}")
                }
        }
        connectionRequest.tryEmit(false)
        environmentState.value = EnvironmentState.Disconnected
        environmentScope.cancel()
    }

    fun getCachedIdes(): List<CachedIdeStub> {
        val ideHint = link.ideHint?.trim()?.takeIf { it.isNotEmpty() } ?: return emptyList()
        return listOf(
            LinkCachedIdeStub(ideHint)
        )
    }

    fun getProjects(): List<CachedProject> {
        val projectPath = link.projectPath?.trim()?.takeIf { it.isNotEmpty() } ?: return emptyList()
        val projectName = projectPath
            .trimEnd('/', '\\')
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .ifBlank { projectPath }

        return listOf(
            CachedProject(
                path = projectPath,
                name = projectName,
                location = projectPath,
            ).apply {
                setBeforeProjectOpenedHook { handleBeforeProjectOpen() }
            }
        )
    }
}

private data class LinkCachedIdeStub(
    override val productCode: String,
) : CachedIdeStub {
    override fun isRunning(): Boolean? = null
}
