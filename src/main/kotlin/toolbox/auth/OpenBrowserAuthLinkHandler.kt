package toolbox.auth

import java.awt.Desktop
import java.net.URI

class OpenBrowserAuthLinkHandler : AuthLinkHandler {
    override fun handleAuthLink(getLink: () -> URI, newRoute: Boolean) {
        if (Desktop.isDesktopSupported() &&
            Desktop.getDesktop().isSupported(Desktop.Action.BROWSE)
        ) {
            Desktop.getDesktop().browse(getLink())
        }
    }
}