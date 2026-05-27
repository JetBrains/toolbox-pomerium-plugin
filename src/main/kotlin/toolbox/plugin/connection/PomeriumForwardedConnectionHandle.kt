package toolbox.plugin.connection

import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.remoteDev.connection.ForwardedConnection
import com.jetbrains.toolbox.api.remoteDev.connection.ForwardedConnectionHandle
import kotlinx.coroutines.CoroutineScope
import toolbox.auth.PomeriumTunneler
import toolbox.plugin.models.DevEnvConnectionInfo
import toolbox.plugin.models.EnvironmentState
import toolbox.plugin.models.PomeriumEnvironment
import toolbox.plugin.models.toEnvironmentState
import java.net.InetAddress
import java.net.URI

class PomeriumForwardedConnectionHandle(
    private val tunneler: PomeriumTunneler,
    private val logger: Logger,
    private val connectionInfo: DevEnvConnectionInfo,
    private val devEnv: PomeriumEnvironment,
    private val environmentScope: CoroutineScope,
    private val remoteAddress: InetAddress,
    private val remotePort: Int,
    private val localAddress: InetAddress
) : ForwardedConnectionHandle {
    @Volatile
    private var tunnelRoute: URI? = null

    override suspend fun getForwardedConnection(): ForwardedConnection {
        logger.info("Starting tunnel to remote address: $remoteAddress:$remotePort")
        val route = URI(connectionInfo.url)
        tunnelRoute = route
        val port = tunneler.startTunnel(
            route = route,
            authScope = environmentScope,
            pomeriumPort = 443,
            useTls = true,
            ensureUpstreamReady = true,
            onStateChange = { devEnv.setEnvironmentState(it.toEnvironmentState()) },
        )
        return ForwardedConnection(port, remotePort)
    }

    override fun close() {
        tunnelRoute?.let { tunneler.closeTunnel(it) }
        devEnv.setEnvironmentState(EnvironmentState.Disconnected)
    }
}
