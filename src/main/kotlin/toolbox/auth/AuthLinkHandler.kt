package toolbox.auth

import java.net.URI

interface AuthLinkHandler {
    /**
     * Called when authentication is required but not valid for a route. Its up to the implementer
     * to have the user perform authentication in a browser on the same machine at some point.
     * @param getLink Call this to fetch the latest link to direct the user to
     * @param newRoute True if this is a new route during the JVM lifetime
     */
    fun handleAuthLink(getLink: () -> URI, newRoute: Boolean)
}