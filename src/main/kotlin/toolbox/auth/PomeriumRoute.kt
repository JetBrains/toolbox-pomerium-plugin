package toolbox.auth

import java.net.URI

fun normalizePomeriumRoute(route: URI, useTls: Boolean): URI {
    if (!useTls || !route.scheme.equals("tcp", ignoreCase = true) || route.host == null) {
        return route
    }

    return URI(
        "https",
        route.userInfo,
        route.host,
        route.port,
        route.path,
        route.query,
        route.fragment,
    )
}
