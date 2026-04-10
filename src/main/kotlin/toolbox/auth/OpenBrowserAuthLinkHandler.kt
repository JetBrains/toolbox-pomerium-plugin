package toolbox.auth

import java.awt.Desktop
import java.net.URI

class OpenBrowserAuthLinkHandler : AuthLinkHandler {
    override fun handleAuthLink(getLink: () -> URI, newRoute: Boolean) {
        Desktop.getDesktop().browse(getLink())
    }
}