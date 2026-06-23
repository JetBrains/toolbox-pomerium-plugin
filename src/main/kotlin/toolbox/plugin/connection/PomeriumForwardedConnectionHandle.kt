package toolbox.plugin.connection

import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.remoteDev.connection.ForwardedConnection
import com.jetbrains.toolbox.api.remoteDev.connection.ForwardedConnectionHandle
import kotlinx.coroutines.CoroutineScope
import toolbox.auth.PomeriumTunneler
import toolbox.auth.normalizePomeriumRoute
import toolbox.plugin.models.DevEnvConnectionInfo
import toolbox.plugin.models.PomeriumEnvironment
import toolbox.plugin.models.toEnvironmentState
import java.net.InetAddress
import java.net.URI
import java.util.concurrent.atomic.AtomicInteger

private val forwardedConnectionIdCounter = AtomicInteger(0)

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
    private val connectionId = forwardedConnectionIdCounter.incrementAndGet()
    private val leaseId = "backend-$connectionId"

    @Volatile
    private var tunnelRoute: URI? = null

    @Volatile
    private var leaseRegistered = false

    override suspend fun getForwardedConnection(): ForwardedConnection {
        val route = normalizePomeriumRoute(URI(connectionInfo.url), useTls = true)
        logger.info(
            "Starting forwarded IDE tunnel. " +
                    "requestedRemote=${remoteAddress.hostAddress}:$remotePort, " +
                    "localAddress=${localAddress.hostAddress}, " +
                    "configuredRoute=${route}, " +
                    "pomeriumPort=${connectionInfo.pomeriumPort}"
        )
        tunnelRoute = route
        logger.info(
            "Resolved forwarded IDE route: scheme=${route.scheme}, host=${route.host}, port=${route.port}, authority=${route.authority}"
        )
        val port = tunneler.startTunnel(
            route = route,
            authScope = environmentScope,
            pomeriumPort = connectionInfo.pomeriumPort,
            useTls = true,
            ensureUpstreamReady = true,
            onStateChange = { devEnv.setEnvironmentState(it.toEnvironmentState()) },
        )
        devEnv.registerConnectionLease(leaseId, "backend", route)
        leaseRegistered = true
        logger.info(
            "Forwarded IDE tunnel is listening on 127.0.0.1:$port and mapped for requested remote port $remotePort"
        )
        return ForwardedConnection(port, remotePort)
    }

    override fun close() {
        tunnelRoute?.let { route ->
            tunneler.closeTunnel(route)
            if (leaseRegistered) {
                devEnv.releaseConnectionLease(leaseId, "backend", route)
                leaseRegistered = false
            }
        }
        tunnelRoute = null
    }
}
