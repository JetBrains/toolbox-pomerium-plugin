package toolbox.plugin.connection

import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.remoteDev.connection.ForwardedConnectionHandle
import com.jetbrains.toolbox.api.remoteDev.connection.HostTunnelConnector
import toolbox.auth.PomeriumTunneler
import toolbox.plugin.models.DevEnvConnectionInfo
import java.net.InetAddress

class PomeriumHostTunnelConnector(
    private val tunneler: PomeriumTunneler,
   private val connectionInfo: DevEnvConnectionInfo,
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
        return  PomeriumForwardedConnectionHandle(tunneler, logger, connectionInfo, remoteAddress, remotePort, localAddress)
    }
}

