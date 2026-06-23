package toolbox.plugin

import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.core.util.LoadableState
import com.jetbrains.toolbox.api.remoteDev.connection.AgentConnection
import com.jetbrains.toolbox.api.remoteDev.connection.AgentConnectionHandle
import com.jetbrains.toolbox.api.remoteDev.connection.HostTunnelConnector
import com.jetbrains.toolbox.api.remoteDev.connection.RemoteToolsHelper
import com.jetbrains.toolbox.api.remoteDev.environments.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import toolbox.auth.PomeriumTunneler
import toolbox.auth.normalizePomeriumRoute
import toolbox.plugin.connection.PomeriumHostTunnelConnector
import toolbox.plugin.models.DevEnvConnectionInfo
import toolbox.plugin.models.PomeriumEnvironment
import toolbox.plugin.models.toEnvironmentState
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger


class PomeriumEnvironmentContentsView(
    private val pluginScope: CoroutineScope,
    private val logger: Logger,
    private val devEnv: PomeriumEnvironment,
    private val tunneler: PomeriumTunneler,
    private val remoteToolsHelper: RemoteToolsHelper,
    private val beforeProjectOpen: suspend () -> Unit,
    val info: DevEnvConnectionInfo
) : PortForwardingCapableEnvironmentContentsView,
    AgentConnectionBasedEnvironmentContentsView,
    ManualEnvironmentContentsView {
    private var refreshInstalledIdeListJob: Job? = null

    override fun getSupportsRedeploy(): Boolean = true

    private fun createProject(path: String, name: String, location: String): CachedProject =
        CachedProject(path = path, name = name, location = location).apply {
            setBeforeProjectOpenedHook { beforeProjectOpen() }
        }


    override val ideListState: MutableStateFlow<LoadableState<List<CachedIdeStub>>> =
        MutableStateFlow(LoadableState.Value(devEnv.getCachedIdes()))

    override val projectListState: MutableStateFlow<LoadableState<List<CachedProject>>> =
        MutableStateFlow(LoadableState.Value(devEnv.getProjects()))

    fun refreshInstalledIdeListAsync() {
        refreshInstalledIdeListJob?.cancel()
        refreshInstalledIdeListJob = pluginScope.launch {
            refreshInstalledIdeList()
        }
    }

    suspend fun refreshInstalledIdeList() {
        ideListState.value = LoadableState.Loading
        ideListState.value = LoadableState.Value(loadInstalledIdeStubs())
    }

    private suspend fun loadInstalledIdeStubs(): List<CachedIdeStub> {
        val installedTools = runCatching {
            remoteToolsHelper.getInstalledRemoteTools(devEnv.id, "")
        }.onFailure { error ->
            logger.warn("Failed to load installed remote tools for '${devEnv.id}': ${error.message}")
        }.getOrElse { emptyList() }

        val toolHints = buildList {
            addAll(devEnv.getCachedIdes().map { it.productCode })
            addAll(installedTools)
        }

        return toolHints
            .asSequence()
            .map(String::trim)
            .filter(String::isNotEmpty)
            .distinct()
            .sorted()
            .map(::RemoteToolCachedIdeStub)
            .toList()
    }

    override fun getHostTunnelConnector(): HostTunnelConnector {
        return PomeriumHostTunnelConnector(tunneler, info, devEnv, pluginScope, logger)
    }

    override fun getAgentConnectionHandle(redeploy: Boolean): AgentConnectionHandle {
        return PomeriumBasedAgentConnectionHandle(
            pluginScope,
            tunneler,
            logger,
            info,
            devEnv,
        )
    }
}

private data class RemoteToolCachedIdeStub(
    override val productCode: String,
) : CachedIdeStub {
    override fun isRunning(): Boolean? = null
}

private var connectionIdCounter = AtomicInteger(0)

class PomeriumBasedAgentConnectionHandle(
    private val pluginScope: CoroutineScope,
    private val tunneler: PomeriumTunneler,
    private val logger: Logger,
    private val connectionInfo: DevEnvConnectionInfo,
    private val devEnv: PomeriumEnvironment,
) : AgentConnectionHandle {
    private val connectionId = connectionIdCounter.incrementAndGet()
    private val connectionLogPrefix = "TbaConnection($connectionId)"
    private val leaseId = "agent-$connectionId"

    private val agentConnectionScope =
        CoroutineScope(
            pluginScope.coroutineContext
                    + CoroutineName(connectionLogPrefix)
                    + Dispatchers.IO
                    + Job(pluginScope.coroutineContext.job)
        )
    private val closed = AtomicBoolean(false)

    @Volatile
    private var agentSocket: Socket? = null

    @Volatile
    private var tunnelRoute: URI? = null

    @Volatile
    private var leaseRegistered = false

    override suspend fun getAgentConnection(): AgentConnection {
        return try {
            logger.debug("$connectionLogPrefix: start")
            val (_, agentRelayUrl, agentRelayAuthData, pomeriumPort) = connectionInfo
            logger.info("Starting agent tunnel")
            val route = normalizePomeriumRoute(URI(agentRelayUrl), useTls = true)
            tunnelRoute = route

            val port = tunneler.startTunnel(
                route = route,
                authScope = agentConnectionScope,
                pomeriumPort = pomeriumPort,
                onStateChange = { devEnv.setEnvironmentState(it.toEnvironmentState()) },
            )
            devEnv.registerConnectionLease(leaseId, "agent", route)
            leaseRegistered = true
            logger.info("Starting connecting to port: ${port}")

            withContext(Dispatchers.IO) {
                val currentSocket = Socket()
                try {
                    currentSocket.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port))
                    val input = currentSocket.getInputStream()
                    val output = currentSocket.getOutputStream()
                    agentRelayAuthData?.let {
                        output.write(it.toByteArray(Charsets.UTF_8))
                        output.flush()
                    }
                    agentSocket = currentSocket
                    AgentConnection(input, output)
                } catch (e: Throwable) {
                    runCatching { currentSocket.close() }
                    throw e
                }
            }
        } catch (e: Throwable) {
            cleanupOnFailure()
            agentConnectionScope.cancel("AgentConnectionHandle.getAgentConnection failed with [${e::class.simpleName}] ${e.message}")
            throw e
        }
    }

    override suspend fun close() {
        if (!closed.compareAndSet(false, true)) return
        val socket = agentSocket
        agentSocket = null
        runCatching { socket?.close() }
            .onFailure { e -> logger.warn("$connectionLogPrefix: failed to close agent socket ${e.message}") }
        tunnelRoute?.let { route ->
            runCatching { tunneler.closeTunnel(route) }
                .onFailure { e -> logger.warn("$connectionLogPrefix: failed to close tunnel for $route: ${e.message}") }
            if (leaseRegistered) {
                devEnv.releaseConnectionLease(leaseId, "agent", route)
                leaseRegistered = false
            }
        }
        tunnelRoute = null
        agentConnectionScope.cancel("$connectionLogPrefix: connection handle closed")
    }

    private fun cleanupOnFailure() {
        val socket = agentSocket
        agentSocket = null
        runCatching { socket?.close() }
        val route = tunnelRoute
        if (route != null) {
            runCatching { tunneler.closeTunnel(route) }
            if (leaseRegistered) {
                devEnv.releaseConnectionLease(leaseId, "agent", route)
                leaseRegistered = false
            }
        }
        tunnelRoute = null
    }
}
