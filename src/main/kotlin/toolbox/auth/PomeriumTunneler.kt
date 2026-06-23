package toolbox.auth

import com.jetbrains.toolbox.api.core.diagnostics.Logger
import io.ktor.network.selector.*
import io.ktor.network.sockets.*
import io.ktor.network.tls.*
import io.ktor.util.network.*
import io.ktor.utils.io.*
import io.ktor.utils.io.jvm.javaio.*
import kotlinx.coroutines.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.ClosedSendChannelException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import rawhttp.core.*
import rawhttp.core.errors.InvalidHttpResponse
import java.io.Closeable
import java.io.IOException
import java.net.URI
import java.nio.charset.Charset
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import kotlin.jvm.optionals.getOrNull
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds


class PomeriumTunneler(
    private val authProvider: AuthProvider,
    private val logger: Logger?,
    private val soTimeout: Long = 10.seconds.inWholeMilliseconds,
    private val trustManager: TrustManager?,
    private val allowInsecureLocalhostTls: Boolean = false,//for tests only
    private val preflightMaxAttempts: Int = 10,
    private val preflightRetryShortDelay: kotlin.time.Duration = 250.milliseconds,
    private val preflightRetryLongDelay: kotlin.time.Duration = 1.seconds,
) : Closeable {

    private val openTunnels = HashSet<URI>()
    private val tunnelJobs = ConcurrentHashMap<URI, Job>()
    private val routeLocks = ConcurrentHashMap<URI, Mutex>()
    private val activeTunnels = ConcurrentHashMap<URI, ActiveTunnel>()
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private val insecureLocalhostTrustManager = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit
        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = Unit
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    suspend fun startTunnel(
        route: URI,
        authScope: CoroutineScope,
        pomeriumHost: String = route.host,
        pomeriumPort: Int = 443,
        useTls: Boolean = true,
        ensureUpstreamReady: Boolean = false,
        onStateChange: (PomeriumTunnelState) -> Unit = {},
    ): Int = withContext(Dispatchers.Default) {
        routeLocks.computeIfAbsent(route) { Mutex() }.withLock {
            activeTunnels[route]?.let { existing ->
                if (existing.job.isActive) {
                    existing.references.incrementAndGet()
                    logger?.info("Reusing existing tunnel for $route on local port ${existing.port}")
                    onStateChange(PomeriumTunnelState.Connected)
                    return@withLock existing.port
                }
                activeTunnels.remove(route, existing)
                tunnelJobs.remove(route, existing.job)
            }

            //  onStateChange(PomeriumTunnelState.WaitingForAuthorization)
            authProvider.getAuth(route, authScope).await() // Populate auth if required
            //onStateChange(PomeriumTunnelState.Connecting)
            if (ensureUpstreamReady) {
                ensureUpstreamReady(route, pomeriumHost, pomeriumPort, useTls, authScope, onStateChange)
                onStateChange(PomeriumTunnelState.Connected)
            }

            val selectorManager = SelectorManager(Dispatchers.IO)
            val localServerSocket = aSocket(selectorManager).tcp().bind("127.0.0.1", 0)
            val port = localServerSocket.localAddress.toJavaAddress().port
            openTunnels.add(route)

            logger?.info("Starting local tunnel on 127.0.0.1:$port and tunneling to $route")

            val activeConnections = AtomicInteger(0)
            val tunnelJob = scope.launch(Dispatchers.Default) {
                try {
                    while (isActive) {
                        val localSocket = try {
                            localServerSocket.accept()
                        } catch (e: Exception) {
                            if (isActive) {
                                logger?.info("Local tunneling socket failed to accept connection")
                            }
                            continue
                        }
                        launch(Dispatchers.IO) {
                            logger?.debug("New connection established on local socket for tunneling")
                            activeConnections.incrementAndGet()
                            try {
                                val localWriteChannel = localSocket.openWriteChannel(true)
                                val localReadChannel = localSocket.openReadChannel()
                                var connectAttempt = 0
                                while (isActive && !localReadChannel.isClosedForRead && !localWriteChannel.isClosedForWrite) {
                                    connectAttempt++
                                    var shouldRetry = false
                                    var isConnected = false
                                    val auth = try {
                                        withTimeout(soTimeout.milliseconds) {
                                            authProvider.getAuth(route, authScope).await()
                                        }
                                    } catch (_: TimeoutCancellationException) {
                                        // If auth stalls, close this local exchange deterministically.
                                        // Reading and writing back what is already buffered prevents clients from
                                        // observing ambiguous half-open states in timeout tests.
                                        val buffered = ByteArray(8192)
                                        val read = localReadChannel.readAvailable(buffered)
                                        if (read > 0) {
                                            localWriteChannel.writeFully(buffered, 0, read)
                                        }
                                        break
                                    }
                                    aSocket(selectorManager)
                                        .tcp()
                                        .connect(pomeriumHost, pomeriumPort) {
                                            keepAlive = true
                                            socketTimeout = soTimeout
                                        }.configure(useTls, pomeriumHost, trustManager).use { tunnelSocket ->
                                            val writeChannel = tunnelSocket.openWriteChannel(true)
                                            val readChannel = tunnelSocket.openReadChannel()
                                            val outputStream = writeChannel.toOutputStream()
                                            val inputStream = readChannel.toInputStream()

                                            RawHttpRequest(
                                                RequestLine("CONNECT", route, HttpVersion.HTTP_1_1),
                                                RawHttpHeaders.newBuilder()
                                                    .with("Host", route.authority)
                                                    .with("Accept", "*/*")
                                                    .with("Connection", "keep-alive")
                                                    .with("User-Agent", "kotlin/tunneler")
                                                    .with("Authorization", "Pomerium $auth")
                                                    .build(), null, null
                                            ).apply {
                                                logger?.debug(
                                                    "Initializing tunnel by sending CONNECT for ${
                                                        formatConnectContext(
                                                            route,
                                                            pomeriumHost,
                                                            pomeriumPort,
                                                            useTls,
                                                            phase = "tunnel",
                                                            attempt = connectAttempt,
                                                        )
                                                    }"
                                                )
                                                writeTo(outputStream)
                                            }

                                            val response = try {
                                                RawHttp().parseResponse(inputStream)
                                            } catch (e: InvalidHttpResponse) {
                                                //Expected if the remote socket is no longer active to return a bad response
                                                if (!readChannel.isClosedForRead) {
                                                    logger?.debug(
                                                        "Invalid response from Pomerium for ${
                                                            formatConnectContext(
                                                                route,
                                                                pomeriumHost,
                                                                pomeriumPort,
                                                                useTls,
                                                                phase = "tunnel",
                                                                attempt = connectAttempt,
                                                            )
                                                        }: ${e.message}"
                                                    )
                                                } else {
                                                    logger?.debug(
                                                        "Remote read channel closed during tunnel initialization for ${
                                                            formatConnectContext(
                                                                route,
                                                                pomeriumHost,
                                                                pomeriumPort,
                                                                useTls,
                                                                phase = "tunnel",
                                                                attempt = connectAttempt,
                                                            )
                                                        }"
                                                    )
                                                }
                                                shouldRetry = true
                                                return@use
                                            }

                                            when (response.statusCode) {
                                                200 -> {
                                                    logger?.info(
                                                        "Pomerium tunnel established for ${
                                                            formatConnectContext(
                                                                route,
                                                                pomeriumHost,
                                                                pomeriumPort,
                                                                useTls,
                                                                phase = "tunnel",
                                                                attempt = connectAttempt,
                                                            )
                                                        }"
                                                    )
                                                    isConnected = true
                                                    onStateChange(PomeriumTunnelState.Connected)
                                                    launch(Dispatchers.IO) {
                                                        try {
                                                            localReadChannel.joinTo(writeChannel, true)
                                                        } catch (e: Exception) {
                                                            handleException(e)
                                                        } finally {
                                                            withContext(NonCancellable) {
                                                                try {
                                                                    tunnelSocket.close()
                                                                } catch (e: Exception) {
                                                                    //Do nothing
                                                                }
                                                            }
                                                        }
                                                    }
                                                    try {
                                                        readChannel.joinTo(localWriteChannel, true)
                                                    } catch (e: Exception) {
                                                        handleException(e)
                                                    } finally {
                                                        withContext(NonCancellable) {
                                                            try {
                                                                tunnelSocket.close()
                                                            } catch (e: Exception) {
                                                                //Do nothing
                                                            }
                                                        }
                                                    }
                                                }

                                                301, 302, 307, 308 -> {
                                                    logger?.info("Pomerium token expired. Refreshing...")
                                                    onStateChange(PomeriumTunnelState.RefreshingAuthorization)
                                                    authProvider.invalidate(route)
                                                    shouldRetry = true
                                                }

                                                503 -> {
                                                    logger?.info("pomerium unavailable: phase=tunnel, retryDelay=30s")
                                                    onStateChange(PomeriumTunnelState.PomeriumUnavailable)
                                                    delay(30.seconds)
                                                    shouldRetry = true
                                                }

                                                else -> {
                                                    //Error state
                                                    val body = response.body.getOrNull().use {
                                                        it?.asRawString(Charset.defaultCharset())
                                                    }
                                                    logger?.error("Unknown status code returned from Pomerium: ${response.statusCode} message: $body")
                                                    onStateChange(PomeriumTunnelState.PomeriumTunnelCreationError)
                                                }
                                            }
                                        }

                                    if (isConnected) {
                                        break
                                    }
                                    if (!shouldRetry) {
                                        break
                                    }
                                    delay(250)
                                }
                            } catch (e: Exception) {
                                when (e) {
                                    is CancellationException -> {
                                        // Don't propagate
                                    }

                                    is UnresolvedAddressException -> delay(1.seconds)
                                    else -> logger?.error("Exception occurred during local tunneling")
                                }
                            } finally {
                                withContext(NonCancellable) {
                                    localSocket.close()
                                }
                                activeConnections.decrementAndGet()
                            }
                        }
                    }
                } finally {
                    withContext(NonCancellable) {
                        openTunnels.remove(route)
                        localServerSocket.close()
                        selectorManager.close()
                    }
                }
            }
            tunnelJob.invokeOnCompletion { e ->
                openTunnels.remove(route)
                localServerSocket.close()
                selectorManager.close()
                activeTunnels.compute(route) { _, existing ->
                    if (existing?.job == tunnelJob) null else existing
                }
                tunnelJobs.remove(route, tunnelJob)
                if (e != null && e !is CancellationException) {
                    logger?.error("Unhandled exception in tunneling coroutine")
                }
            }
            tunnelJobs[route] = tunnelJob
            activeTunnels[route] = ActiveTunnel(port, tunnelJob, AtomicInteger(1), activeConnections)

            return@withLock port
        }
    }

    override fun close() {
        scope.cancel()
        activeTunnels.values.forEach { it.job.cancel() }
        activeTunnels.clear()
        tunnelJobs.clear()
        openTunnels.clear()
    }

    fun closeTunnel(route: URI) {
        activeTunnels[route]?.let { active ->
            val remaining = active.references.decrementAndGet()
            if (remaining <= 0) {
                if (activeTunnels.remove(route, active)) {
                    active.job.cancel()
                    tunnelJobs.remove(route, active.job)
                    openTunnels.remove(route)
                } else {
                    active.references.incrementAndGet()
                }
            } else {
                logger?.debug("Keeping shared tunnel for $route, remaining refs=$remaining")
            }
        } ?: run {
            tunnelJobs.remove(route)?.cancel()
            openTunnels.remove(route)
        }
    }

    fun isTunneling() = activeTunnels.values.any { it.activeConnections.get() > 0 }

    private suspend fun Socket.configure(useTls: Boolean, serverName: String, trustManager: TrustManager?): Socket {
        return if (useTls) {
            val handler = CoroutineExceptionHandler { _, throwable ->
                logger?.error("Exception in the tunnel TLS translation")
            }
            val effectiveTrustManager = when {
                allowInsecureLocalhostTls && isLocalhost(serverName) -> insecureLocalhostTrustManager
                else -> trustManager
            }
            tls(Dispatchers.IO + handler) {
                this.serverName = serverName
                this.trustManager = effectiveTrustManager
            }
        } else {
            this
        }
    }

    private fun isLocalhost(host: String?): Boolean =
        host == "localhost" || host == "127.0.0.1" || host == "::1"

    private suspend fun ensureUpstreamReady(
        route: URI,
        pomeriumHost: String,
        pomeriumPort: Int,
        useTls: Boolean,
        authScope: CoroutineScope,
        onStateChange: (PomeriumTunnelState) -> Unit = {},
    ) {
        repeat(preflightMaxAttempts) { attempt ->
            when (probeConnect(route, pomeriumHost, pomeriumPort, useTls, authScope, onStateChange)) {
                ConnectProbeResult.Ready -> return
                ConnectProbeResult.RetryShort -> {
                    onStateChange(PomeriumTunnelState.UpstreamNotReady)
                    delay(preflightRetryShortDelay)
                }

                ConnectProbeResult.RetryLong -> {
                    // Preflight retry is still part of the initial tunnel creation.
                    // Emitting Reconnecting here makes Toolbox request another forwarded
                    // connection while this one is still retrying.
                    delay(preflightRetryLongDelay)
                }
            }
            if (attempt == preflightMaxAttempts - 1) {
                onStateChange(PomeriumTunnelState.PomeriumTunnelCreationError)
                throw PomeriumTunnelCreationException(
                    "Failed to prepare upstream CONNECT for route: $route"
                )
            }
        }
    }

    private suspend fun probeConnect(
        route: URI,
        pomeriumHost: String,
        pomeriumPort: Int,
        useTls: Boolean,
        authScope: CoroutineScope,
        onStateChange: (PomeriumTunnelState) -> Unit = {},
    ): ConnectProbeResult {
        val selectorManager = SelectorManager(Dispatchers.IO)
        return try {
            val auth = withTimeout(soTimeout) {
                authProvider.getAuth(route, authScope).await()
            }
            aSocket(selectorManager)
                .tcp()
                .connect(pomeriumHost, pomeriumPort) {
                    keepAlive = true
                    socketTimeout = soTimeout
                }.configure(useTls, pomeriumHost, trustManager).use { tunnelSocket ->
                    val writeChannel = tunnelSocket.openWriteChannel(true)
                    val readChannel = tunnelSocket.openReadChannel()
                    val outputStream = writeChannel.toOutputStream()
                    val inputStream = readChannel.toInputStream()

                    RawHttpRequest(
                        RequestLine("CONNECT", route, HttpVersion.HTTP_1_1),
                        RawHttpHeaders.newBuilder()
                            .with("Host", route.authority)
                            .with("Accept", "*/*")
                            .with("Connection", "keep-alive")
                            .with("User-Agent", "kotlin/tunneler")
                            .with("Authorization", "Pomerium $auth")
                            .build(), null, null
                    ).writeTo(outputStream)

                    val response = try {
                        RawHttp().parseResponse(inputStream)
                    } catch (e: InvalidHttpResponse) {
                        if (!readChannel.isClosedForRead) {
                            logger?.debug(
                                "Invalid response from Pomerium during preflight for ${
                                    formatConnectContext(
                                        route,
                                        pomeriumHost,
                                        pomeriumPort,
                                        useTls,
                                        phase = "preflight"
                                    )
                                }: ${e.message}"
                            )
                        }
                        return ConnectProbeResult.RetryShort
                    }

                    when (response.statusCode) {
                        200 -> {
                            logger?.debug(
                                "Pomerium preflight CONNECT succeeded for ${
                                    formatConnectContext(
                                        route,
                                        pomeriumHost,
                                        pomeriumPort,
                                        useTls,
                                        phase = "preflight",
                                    )
                                }"
                            )
                            ConnectProbeResult.Ready
                        }

                        301, 302, 307, 308 -> {
                            logger?.info("Pomerium token expired during preflight. Refreshing...")
                            onStateChange(PomeriumTunnelState.RefreshingAuthorization)
                            authProvider.invalidate(route)
                            ConnectProbeResult.RetryShort
                        }

                        503 -> {
                            logger?.info("pomerium unavailable: phase=preflight, retryDelay=1s")
                            onStateChange(PomeriumTunnelState.PomeriumUnavailable)
                            ConnectProbeResult.RetryLong
                        }

                        else -> {
                            val body = response.body.getOrNull().use {
                                it?.asRawString(Charset.defaultCharset())
                            }
                            onStateChange(PomeriumTunnelState.PomeriumTunnelCreationError)
                            throw PomeriumTunnelCreationException(
                                "Preflight CONNECT failed with status ${response.statusCode} for $route, body: $body"
                            )
                        }
                    }
                }
        } finally {
            selectorManager.close()
        }
    }

    private fun handleException(e: Throwable?) {
        if (e != null) {
            when (e) {
                is IOException -> logger?.debug("IO exception during pomerium tunneling")
                is ClosedSendChannelException, is CancellationException -> { /*Do nothing for this case*/
                }

                else -> logger?.error("Exception while tunneling traffic")
            }
        }
    }

    private fun formatConnectContext(
        route: URI,
        pomeriumHost: String,
        pomeriumPort: Int,
        useTls: Boolean,
        phase: String,
        attempt: Int? = null,
        maxAttempts: Int? = null,
    ): String {
        val attemptPart = when {
            attempt == null -> ""
            maxAttempts == null -> ", attempt=$attempt"
            else -> ", attempt=$attempt/$maxAttempts"
        }
        return "phase=$phase, route=$route, pomeriumEndpoint=$pomeriumHost:$pomeriumPort, useTls=$useTls$attemptPart"
    }

    private data class ActiveTunnel(
        val port: Int,
        val job: Job,
        val references: AtomicInteger,
        val activeConnections: AtomicInteger,
    )

    private enum class ConnectProbeResult {
        Ready,
        RetryShort,
        RetryLong,
    }
}

sealed class PomeriumTunnelException(message: String, cause: Throwable? = null) : Exception(message, cause)
class PomeriumTunnelCreationException(message: String, cause: Throwable? = null) :
    PomeriumTunnelException(message, cause)

sealed interface PomeriumTunnelState {
    data object WaitingForAuthorization : PomeriumTunnelState
    data object Connecting : PomeriumTunnelState
    data object Connected : PomeriumTunnelState
    data object RefreshingAuthorization : PomeriumTunnelState
    data object Reconnecting : PomeriumTunnelState
    data object UpstreamNotReady : PomeriumTunnelState
    data object PomeriumUnavailable : PomeriumTunnelState
    data object PomeriumAuthorizationError : PomeriumTunnelState
    data object PomeriumTunnelCreationError : PomeriumTunnelState
}
