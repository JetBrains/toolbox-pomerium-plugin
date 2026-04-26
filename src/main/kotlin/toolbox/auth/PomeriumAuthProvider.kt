package toolbox.auth

import com.jetbrains.toolbox.api.core.PluginSecretStoreSuspending
import com.jetbrains.toolbox.api.core.auth.SSLSettings
import io.ktor.client.*
import io.ktor.client.engine.okhttp.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.apache.http.client.utils.URIBuilder
import org.slf4j.LoggerFactory
import java.io.Closeable
import java.net.URI
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Service for getting authentication for pomerium controlled routes.
 * Handles caching and reuse by using the pomerium authentication host as a key
 * When a new token is needed, this code will perform a device flow to obtain and cache the token from Pomerium
 */
class PomeriumAuthProvider(
    private val credentialStore: PluginSecretStoreSuspending,
    private val linkHandler: AuthLinkHandler = OpenBrowserAuthLinkHandler(),
    private val pomeriumPort: Int = 443,
    sslSettings: SSLSettings? = null,
    private val allowInsecureLocalhostTls: Boolean = false,
) : AuthProvider {

    private val credKeyToMutexMap = ConcurrentHashMap<CredentialKey, Mutex>()
    private val routeToMutexMap = ConcurrentHashMap<URI, Mutex>()
    private val credKeyToAuthJobMap = ConcurrentHashMap<CredentialKey, Deferred<String>>()
    private val routeToCredKeyMap = ConcurrentHashMap<URI, CredentialKey>()
    private val existingRoutes = Collections.newSetFromMap(ConcurrentHashMap<URI, Boolean>())

    private val secureClient = HttpClient(OkHttp) {
        if (sslSettings != null) {
            val sslSocketFactory = sslSettings.getSocketFactory()
            val trustManager = sslSettings.getTrustManager()
            if (sslSocketFactory != null && trustManager != null) {
                engine {
                    config {
                        sslSocketFactory(sslSocketFactory, trustManager)
                    }
                }
            }
        }
    }
    private val insecureLocalhostClient = HttpClient(OkHttp) {
        engine {
            config {
                val trustAll = object : X509TrustManager {
                    override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit
                    override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = Unit
                    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
                }
                val sslContext = SSLContext.getInstance("TLS").apply {
                    init(null, arrayOf<TrustManager>(trustAll), SecureRandom())
                }
                sslSocketFactory(sslContext.socketFactory, trustAll)
                hostnameVerifier { host, _ -> isLocalhost(host) }
            }
        }
    }
    // todo: proper job cancellation

    override suspend fun getAuth(route: URI): Deferred<String> =
        withContext(Dispatchers.Default) {
            LOG.info("Getting pomerium auth token for $route")
            //Check for existing job. Note, this is not guaranteed to be thread safe, but it does not require a network call.
            //There is another, thread-safe check below.
            routeToCredKeyMap[route]?.let {
                credKeyToMutexMap.computeIfAbsent(it) { Mutex() }.withLock {
                    credentialStore[it]?.let { auth ->
                        return@withContext CompletableDeferred(auth)
                    }
                    credKeyToAuthJobMap[it]?.let { job ->
                        LOG.debug("Existing auth job found in cache, reusing job")

                        return@withContext job
                    }
                }
            }
            // Serialize bootstrap requests for the same route to avoid spawning
            // multiple callback servers and login requests in parallel.
            routeToMutexMap.computeIfAbsent(route) { Mutex() }.withLock {
                routeToCredKeyMap[route]?.let {
                    credKeyToMutexMap.computeIfAbsent(it) { Mutex() }.withLock {
                        credentialStore[it]?.let { auth ->
                            return@withContext CompletableDeferred(auth)
                        }
                        credKeyToAuthJobMap[it]?.let { job ->
                            LOG.debug("Existing auth job found in cache, reusing job")
                            return@withContext job
                        }
                    }
                }

                val callbackServer = PomeriumAuthCallbackServer()
                val serverPort = callbackServer.start()

                LOG.info("Starting HTTP server on port $serverPort for pomerium auth token callback")

                val authLink = getAuthLink(route, pomeriumPort, serverPort)
                val credString = getCredString(authLink)
                return@withLock credKeyToMutexMap.computeIfAbsent(credString) { Mutex() }.withLock {
                    credentialStore[credString]?.let { auth ->
                        callbackServer.close()
                        return@withLock CompletableDeferred(auth)
                    }
                    credKeyToAuthJobMap[credString]?.let {
                        callbackServer.close()
                        LOG.debug("Existing auth job found, reusing job")
                        return@withLock it
                    }
                    routeToCredKeyMap[route] = credString
                    val isNewRoute = existingRoutes.add(route)
                    val getToken = GlobalScope.async(Dispatchers.Default) {
                        try {
                            val auth = callbackServer.getToken()
                            LOG.info("Successfully acquired Pomerium authentication")
                            credentialStore[credString] = auth
                            return@async auth
                        } finally {
                            withContext(NonCancellable) {
                                credKeyToMutexMap[credString]!!.withLock {
                                    credKeyToAuthJobMap.remove(credString)
                                    callbackServer.close()
                                }

                            }
                        }
                    }
                    credKeyToAuthJobMap[credString] = getToken
                    val linkRequested = AtomicBoolean(false)
                    linkHandler.handleAuthLink({
                        linkRequested.set(true)
                        runBlocking { getAuthLink(route, pomeriumPort, serverPort) }
                    }, isNewRoute)
                    if (!linkRequested.get() && linkHandler::class.simpleName != "NoOpAuthLinkHandler") {
                        getToken.cancel()
                    }
                    return@withLock getToken
                }
            }
        }

    override suspend fun invalidate(route: URI) {
        (routeToCredKeyMap.remove(route) ?: run {
            //Port does not matter in this case
            val link = getAuthLink(route, pomeriumPort, 8080)
            getCredString(link)
        }).also {
            credKeyToMutexMap.computeIfAbsent(it) { Mutex() }.withLock {
                credentialStore.clear(it)
                credKeyToAuthJobMap.remove(it)
            }
        }
    }

    private suspend fun getAuthLink(route: URI, pomeriumPort: Int, callbackServerPort: Int): URI {
        val authScheme = if (route.scheme.equals("https", ignoreCase = true) || pomeriumPort == 443) "https" else "http"
        val uri = URIBuilder(route)
            .setScheme(authScheme)
            .setPort(pomeriumPort)
            .setPath(POMERIUM_LOGIN_ENDPOINT)
            .setParameter(POMERIUM_LOGIN_REDIRECT_PARAM, "http://localhost:$callbackServerPort")
            .build()
        val client = if (allowInsecureLocalhostTls && isLocalhost(route.host)) insecureLocalhostClient else secureClient
        val link = client.get(uri.toURL()).bodyAsText()
        return URI.create(link)
    }

    private fun isLocalhost(host: String?): Boolean =
        host == "localhost" || host == "127.0.0.1" || host == "::1"

    companion object {
        const val POMERIUM_LOGIN_ENDPOINT = "/.pomerium/api/v1/login"
        const val POMERIUM_LOGIN_REDIRECT_PARAM = "pomerium_redirect_uri"
        const val POMERIUM_JWT_QUERY_PARAM = "pomerium_jwt"

        private val LOG = LoggerFactory.getLogger(PomeriumAuthProvider::class.java.name)

        fun getCredString(authLink: URI): CredentialKey = "Pomerium instance ${authLink.host}"
    }

    private class PomeriumAuthCallbackServer : Closeable {
        val tokenFuture = CompletableDeferred<String>()

        val server = embeddedServer(Netty, 0) {
            routing {
                get("/") {
                    val jwtQuery = call.parameters[POMERIUM_JWT_QUERY_PARAM]
                    if (jwtQuery != null) {
                        call.respondText(RESPONSE)
                        tokenFuture.complete(jwtQuery)
                    } else {
                        call.respondText(RESPONSE_FAILURE)
                    }
                }
                route("*") {
                    handle {
                        call.respondText(RESPONSE_FAILURE)
                    }
                }
            }
        }

        suspend fun start(): Int {
            return server.start().resolvedConnectors().first().port
        }

        override fun close() {
            server.stop()
        }

        suspend fun getToken(): String {
            return tokenFuture.await()
        }

        companion object {
            const val RESPONSE = "Authentication successful. You may now close this tab."
            const val RESPONSE_FAILURE = "Failed to capture Pomerium jwt."
        }

    }
}
