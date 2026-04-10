package toolbox.plugin

import com.jetbrains.toolbox.api.core.ServiceLocator
import com.jetbrains.toolbox.api.remoteDev.RemoteDevExtension
import com.jetbrains.toolbox.api.remoteDev.RemoteProvider

class PomeriumRemoteDevExtension : RemoteDevExtension {
    override fun createRemoteProviderPluginInstance(serviceLocator: ServiceLocator): RemoteProvider {
        return PomeriumRemoteProvider(serviceLocator)
    }
}
