package toolbox.plugin.models

import com.jetbrains.toolbox.api.core.diagnostics.Logger
import com.jetbrains.toolbox.api.localization.LocalizableStringFactory
import com.jetbrains.toolbox.api.remoteDev.connection.RemoteToolsHelper
import com.jetbrains.toolbox.api.remoteDev.states.EnvironmentStateColorPalette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.mockito.kotlin.*
import toolbox.auth.PomeriumTunneler
import java.net.URI

class PomeriumEnvironmentTest {
    @Test
    fun `close shuts down every registered lease`() = runTest {
        val tunneler = mock<PomeriumTunneler>()
        val environment = createEnvironment(tunneler = tunneler)
        val route = URI("https://backend.localhost:443")

        environment.registerConnectionLease("agent-1", "agent", route)
        environment.registerConnectionLease("backend-1", "backend", route)

        environment.close()

        verify(tunneler, times(2)).closeTunnel(route)
    }

    @Test
    fun `onDelete closes environment and notifies provider`() = runTest {
        val tunneler = mock<PomeriumTunneler>()
        var deleteRequested = false
        val environment = createEnvironment(
            tunneler = tunneler,
            onDeleteRequested = { deleteRequested = true },
        )
        val route = URI("https://backend.localhost:443")

        environment.registerConnectionLease("agent-1", "agent", route)
        checkNotNull(environment.deleteActionFlow.value).invoke()

        assertTrue(deleteRequested)
        verify(tunneler).closeTunnel(route)
    }

    private fun createEnvironment(
        tunneler: PomeriumTunneler,
        onDeleteRequested: () -> Unit = {},
    ): PomeriumEnvironment {
        val scope = kotlinx.coroutines.CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        return PomeriumEnvironment(
            displayName = "env",
            url = "https://backend.localhost:443",
            clientRoute = "https://backend.localhost:443",
            agentUrl = "https://agent.localhost:443",
            agentAuthData = "token",
            link = PomeriumLink(
                pomeriumInstance = null,
                pomeriumPort = 443,
                projectPath = null,
                ideHint = null,
            ),
            tunneler = tunneler,
            logger = mock<Logger>(),
            i18n = mock<LocalizableStringFactory> {
                on { ptrl(any()) } doReturn mock()
            },
            colorPalette = mock<EnvironmentStateColorPalette>(),
            remoteToolsHelper = mock<RemoteToolsHelper>(),
            pluginScope = scope,
            onDeleteRequested = {
                try {
                    onDeleteRequested()
                } finally {
                    scope.cancel()
                }
            },
        )
    }
}
