package toolbox.plugin.models

import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.localization.LocalizableStringFactory
import com.jetbrains.toolbox.api.remoteDev.*
import com.jetbrains.toolbox.api.remoteDev.TabDefinition.Companion.toolsTab
import com.jetbrains.toolbox.api.remoteDev.environments.EnvironmentContentsView
import com.jetbrains.toolbox.api.remoteDev.states.CustomRemoteEnvironmentStateV2
import com.jetbrains.toolbox.api.remoteDev.states.EnvironmentDescription
import com.jetbrains.toolbox.api.remoteDev.states.EnvironmentStateColorPalette
import com.jetbrains.toolbox.api.remoteDev.states.EnvironmentStateIcons
import com.jetbrains.toolbox.api.remoteDev.states.RemoteEnvironmentState
import com.jetbrains.toolbox.api.remoteDev.states.StandardRemoteEnvironmentState
import com.jetbrains.toolbox.api.ui.actions.ActionDescription
import toolbox.auth.PomeriumTunneler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import toolbox.plugin.PomeriumEnvironmentContentsView
import java.io.Closeable

sealed interface EnvironmentState {
    data object Disconnected : EnvironmentState
    data object Connecting : EnvironmentState
    data object Connected : EnvironmentState
    data object AgentUnavailable : EnvironmentState
    data object AgentConnectionError : EnvironmentState
    data object AgentAuthorizationError : EnvironmentState
    data object PomeriumUnavailable : EnvironmentState
    data object PomeriumAuthorizationError : EnvironmentState
    data object PomeriumTunnelCreationError : EnvironmentState
}
class PomeriumEnvironment(
    name: String,
    val url: String,
    val agentUrl: String,
    val agentAuthData: String?,
    val link: PomeriumLink,
    tunneler: PomeriumTunneler,
    private val logger: Logger,
    i18n: LocalizableStringFactory,
    colorPalette: EnvironmentStateColorPalette,
    pluginScope: CoroutineScope
) : RemoteProviderEnvironment(name), Closeable {

    init {
        logger.info("Initializing pomerium environment")
        logger.info("Environment name: $name")
        logger.info("Environment URL: $url")
        logger.info("Environment agent URL: $agentUrl")
        logger.info("Environment link: ${link.route} ${link.pomeriumInstance}:${link.pomeriumPort}}")
        logger.info("Environment '${id}': initial state ${EnvironmentState.Disconnected::class.simpleName}")
    }
    override val description: MutableStateFlow<EnvironmentDescription> = MutableStateFlow(EnvironmentDescription.General(null))
    override val connectionRequest: MutableSharedFlow<Boolean> = MutableSharedFlow(replay = 1)
    val environmentState: MutableStateFlow<EnvironmentState> = MutableStateFlow(EnvironmentState.Disconnected)

    private val contentsView = PomeriumEnvironmentContentsView(
        pluginScope,
        logger,
        this,
        tunneler,
        ::handleBeforeProjectOpen)

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
        setEnvironmentState(EnvironmentState.Disconnected)
        connectionRequest.emit(false)
    }

    override suspend fun getContentsView(): EnvironmentContentsView = contentsView

    override fun setVisible(visibilityState: EnvironmentVisibilityState) {
    }

    override val supportedFeatures = setOf(RemoteEnvironmentAbility.CAN_RENAME, RemoteEnvironmentAbility.ALWAYS_CONNECTED)

    override val actionsList: StateFlow<List<ActionDescription>> = MutableStateFlow(emptyList())

    override val availableSettingsSections: Set<SettingsSection>
        get() = setOf(
            SettingsSection.ABOUT_ENVIRONMENT, SettingsSection.TOOLS
        )
    override val pageTabs: List<TabDefinition> = listOf(toolsTab())
    override val state: StateFlow<RemoteEnvironmentState> =
        environmentState.map { envState ->
            when (envState) {
                EnvironmentState.Disconnected -> StandardRemoteEnvironmentState.Inactive
                EnvironmentState.Connecting -> StandardRemoteEnvironmentState.Initializing
                EnvironmentState.Connected -> StandardRemoteEnvironmentState.Active
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
                    false,
                    EnvironmentStateIcons.Offline,
                )
                EnvironmentState.PomeriumAuthorizationError -> CustomRemoteEnvironmentStateV2(
                    i18n.ptrl("Authorization failed"),
                    colorPalette.getColor(StandardRemoteEnvironmentState.Failed),
                    false,
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
    }

    override fun close() {
        //environmentScope.cancel()
    }
}
