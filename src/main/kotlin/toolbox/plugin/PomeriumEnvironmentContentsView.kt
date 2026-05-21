package toolbox.plugin

import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.core.util.LoadableState
import com.jetbrains.toolbox.api.remoteDev.connection.AgentConnection
import com.jetbrains.toolbox.api.remoteDev.connection.AgentConnectionHandle
import com.jetbrains.toolbox.api.remoteDev.connection.HostTunnelConnector
import com.jetbrains.toolbox.api.remoteDev.environments.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import toolbox.auth.PomeriumTunneler
import toolbox.plugin.connection.PomeriumHostTunnelConnector
import toolbox.plugin.models.DevEnvConnectionInfo
import toolbox.plugin.models.EnvironmentState
import toolbox.plugin.models.PomeriumEnvironment
import java.io.IOException
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
    private val beforeProjectOpen: suspend () -> Unit,
    val info: DevEnvConnectionInfo
) : PortForwardingCapableEnvironmentContentsView,
    AgentConnectionBasedEnvironmentContentsView,
    ManualEnvironmentContentsView {

    override fun getSupportsRedeploy(): Boolean = true

    private fun createProject(path: String, name: String, location: String): CachedProject =
        CachedProject(path = path, name = name, location = location).apply {
            setBeforeProjectOpenedHook { beforeProjectOpen() }
        }


    override val ideListState: StateFlow<LoadableState<List<CachedIdeStub>>> =
        MutableStateFlow(LoadableState.Value(listOf()))

    override val projectListState: kotlinx.coroutines.flow.Flow<LoadableState<List<CachedProject>>>
        get() = MutableStateFlow(LoadableState.Value(listOf()))


    override fun getHostTunnelConnector(): HostTunnelConnector {
        return PomeriumHostTunnelConnector(tunneler, info, logger)
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

    override suspend fun getAgentConnection(): AgentConnection {
        return try {
            logger.debug("$connectionLogPrefix: start")
            val (_, agentRelayUrl, agentRelayAuthData, pomeriumPort) = connectionInfo
            logger.info("Starting agent tunnel to remote address: $agentRelayUrl")
            val route = URI(agentRelayUrl)
            tunnelRoute = route

            val port = tunneler.startTunnel(
                route = route,
                pomeriumPort = pomeriumPort,

            )
            logger.info("Starting connecting to port: ${port}")

            val currentSocket = Socket()
            try {
                currentSocket.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port))
            } catch (e: IOException) {
                currentSocket.close()
                throw e
            }
            agentSocket = currentSocket

            val output = currentSocket.getOutputStream()
            agentRelayAuthData?.let {
                logger.info("Sending auth data to agent")
                output.write("$it".toByteArray(Charsets.UTF_8))
                output.flush()
            }
            AgentConnection(currentSocket.getInputStream(), output)
        } catch (e: Throwable) {
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
        }
        tunnelRoute = null
        agentConnectionScope.cancel("$connectionLogPrefix: connection handle closed")
        devEnv.setEnvironmentState(EnvironmentState.Disconnected)
    }
}
