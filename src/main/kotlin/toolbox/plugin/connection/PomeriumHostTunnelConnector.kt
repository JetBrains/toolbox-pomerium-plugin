package toolbox.plugin.connection

import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.remoteDev.connection.ForwardedConnectionHandle
import com.jetbrains.toolbox.api.remoteDev.connection.HostTunnelConnector
import kotlinx.coroutines.CoroutineScope
import toolbox.auth.PomeriumTunneler
import toolbox.plugin.models.DevEnvConnectionInfo
import toolbox.plugin.models.PomeriumEnvironment
import java.net.InetAddress

class PomeriumHostTunnelConnector(
    private val tunneler: PomeriumTunneler,
    private val connectionInfo: DevEnvConnectionInfo,
    private val devEnv: PomeriumEnvironment,
    private val environmentScope: CoroutineScope,
    private val logger: Logger,
) : HostTunnelConnector {
    override fun forwardIdePort(
        protocol: HostTunnelConnector.Protocol,
        remoteAddress: InetAddress,
        remotePort: Int,
        localAddress: InetAddress
    ): ForwardedConnectionHandle {
        require(protocol == HostTunnelConnector.Protocol.TCP) {
            "Only TCP is supported by PomeriumHostTunnelConnector2"
        }
        logger.info("Forwarding IDE port via PomeriumHostTunnelConnector to ${remoteAddress.hostAddress}:$remotePort")
        return PomeriumForwardedConnectionHandle(
            tunneler, logger, connectionInfo, devEnv, environmentScope, remoteAddress, remotePort, localAddress
        )
    }
}
