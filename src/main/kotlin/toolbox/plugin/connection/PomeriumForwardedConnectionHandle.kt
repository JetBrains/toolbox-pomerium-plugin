package toolbox.plugin.connection

import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.remoteDev.connection.ForwardedConnection
import com.jetbrains.toolbox.api.remoteDev.connection.ForwardedConnectionHandle
import toolbox.auth.PomeriumTunneler
import toolbox.plugin.models.DevEnvConnectionInfo
import java.net.InetAddress
import java.net.URI

class PomeriumForwardedConnectionHandle(
    private val tunneler: PomeriumTunneler,
    private val logger: Logger,
    private val connectionInfo: DevEnvConnectionInfo,
    private val remoteAddress: InetAddress,
    private val remotePort: Int,
    private val localAddress: InetAddress
) : ForwardedConnectionHandle {
    @Volatile
    private var tunnelRoute: URI? = null

    override suspend fun getForwardedConnection(): ForwardedConnection {
        logger.info("Starting tunnel to remote address: $remoteAddress:$remotePort")
        val host = remoteAddress.hostAddress ?: remoteAddress.hostName
        val route = URI(connectionInfo.url)
        tunnelRoute = route
        val port = tunneler.startTunnel(
            route = route,
            pomeriumPort = 443,
            useTls = true,
            ensureUpstreamReady = true
        )
        return ForwardedConnection(port, remotePort)
    }

    override fun close() {
        tunnelRoute?.let { tunneler.closeTunnel(it) }
    }

}
