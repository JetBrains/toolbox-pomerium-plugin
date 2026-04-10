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
import org.slf4j.LoggerFactory
import rawhttp.core.*
import rawhttp.core.errors.InvalidHttpResponse
import java.io.Closeable
import java.io.IOException
import java.net.URI
import java.nio.charset.Charset
import java.security.cert.X509Certificate
import java.util.HashSet
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import kotlin.jvm.optionals.getOrNull
import kotlin.time.Duration.Companion.seconds


class PomeriumTunneler(
    private val authProvider: AuthProvider,
    private val logger: Logger?,
    private val soTimeout: Long = 10.seconds.inWholeMilliseconds,
    private val trustManager: TrustManager?,
    private val allowInsecureLocalhostTls: Boolean = false//for tests only
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
        pomeriumHost: String = route.host,
        pomeriumPort: Int = 443,
        useTls: Boolean = true,
        ): Int = withContext(Dispatchers.Default) {
        routeLocks.computeIfAbsent(route) { Mutex() }.withLock {
            activeTunnels[route]?.let { existing ->
                if (existing.job.isActive) {
                    existing.references.incrementAndGet()
                    logger?.info("Reusing existing tunnel for $route on local port ${existing.port}")
                    return@withLock existing.port
                }
                activeTunnels.remove(route, existing)
                tunnelJobs.remove(route, existing.job)
            }

            authProvider.getAuth(route).await() //Populate auth if required
            ensureUpstreamReady(route, pomeriumHost, pomeriumPort, useTls)

            val selectorManager = SelectorManager(Dispatchers.IO)
            val localServerSocket = aSocket(selectorManager).tcp().bind("127.0.0.1", 0)
            val port = localServerSocket.localAddress.toJavaAddress().port
            openTunnels.add(route)

            logger?.info("Starting local tunnel on 127.0.0.1:$port and tunneling to $route")

            val tunnelJob = scope.launch(Dispatchers.Default) {
                try {
                    while (isActive) {
                        val localSocket = try {
                            localServerSocket.accept()
                        } catch (e: Exception) {
                            if (isActive) {
                                LOG.info("Local tunneling socket failed to accept connection")
                            }
                            continue
                        }
                        launch(Dispatchers.IO) {
                            LOG.debug("New connection established on local socket for tunneling")
                            try {
                                val localWriteChannel = localSocket.openWriteChannel(true)
                                val localReadChannel = localSocket.openReadChannel()
                                while (isActive && !localReadChannel.isClosedForRead && !localWriteChannel.isClosedForWrite) {
                                    var shouldRetry = false
                                    var isConnected = false
                                    val auth = withTimeout(soTimeout) {
                                        authProvider.getAuth(route).await()
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
                                                LOG.debug("Initializing tunnel by sending CONNECT",)
                                                writeTo(outputStream)
                                            }

                                            val response = try {
                                                RawHttp().parseResponse(inputStream)
                                            } catch (e: InvalidHttpResponse) {
                                                //Expected if the remote socket is no longer active to return a bad response
                                                if (!readChannel.isClosedForRead) {
                                                    LOG.warn("Invalid response from Pomerium: ${e.message}")
                                                } else {
                                                    LOG.debug("Remote read channel closed during tunnel initialization")
                                                }
                                                shouldRetry = true
                                                return@use
                                            }

                                            when (response.statusCode) {
                                                200 -> {
                                                    LOG.info("Pomerium tunnel established")
                                                    isConnected = true
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
                                                    LOG.info("Pomerium token expired. Refreshing...")
                                                    authProvider.invalidate(route)
                                                    shouldRetry = true
                                                }

                                                503 -> {
                                                    LOG.debug("Pomerium returned service unavailable, trying after delay")
                                                    delay(30.seconds)
                                                    shouldRetry = true
                                                }

                                                else -> {
                                                    //Error state
                                                    val body = response.body.getOrNull().use {
                                                        it?.asRawString(Charset.defaultCharset())
                                                    }
                                                    LOG.error("Unknown status code returned from Pomerium: ${response.statusCode} message: $body")
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
                                    else -> LOG.error("Exception occurred during local tunneling", e)
                                }
                            } finally {
                                withContext(NonCancellable) {
                                    localSocket.close()
                                }
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
                    LOG.error("Unhandled exception in tunneling coroutine", e)
                }
            }
            tunnelJobs[route] = tunnelJob
            activeTunnels[route] = ActiveTunnel(port, tunnelJob, AtomicInteger(1))

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

    fun isTunneling() = openTunnels.isNotEmpty()

    private suspend fun Socket.configure(useTls: Boolean, serverName: String, trustManager: TrustManager?): Socket {
        return if (useTls) {
            val handler = CoroutineExceptionHandler { _, throwable ->
                LOG.error("Exception in the tunnel TLS translation", throwable)
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
    ) {
        val maxAttempts = 10
        repeat(maxAttempts) { attempt ->
            when (probeConnect(route, pomeriumHost, pomeriumPort, useTls)) {
                ConnectProbeResult.Ready -> return
                ConnectProbeResult.RetryShort -> delay(250)
                ConnectProbeResult.RetryLong -> delay(1.seconds)
            }
            if (attempt == maxAttempts - 1) {
                throw PomeriumTunnelCreationException("Failed to prepare upstream CONNECT for route: $route")
            }
        }
    }

    private suspend fun probeConnect(
        route: URI,
        pomeriumHost: String,
        pomeriumPort: Int,
        useTls: Boolean,
    ): ConnectProbeResult {
        val selectorManager = SelectorManager(Dispatchers.IO)
        return try {
            val auth = withTimeout(soTimeout) {
                authProvider.getAuth(route).await()
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
                            LOG.warn("Invalid response from Pomerium during preflight: ${e.message}")
                        }
                        return ConnectProbeResult.RetryShort
                    }

                    when (response.statusCode) {
                        200 -> ConnectProbeResult.Ready
                        301, 302, 307, 308 -> {
                            LOG.info("Pomerium token expired during preflight. Refreshing...")
                            authProvider.invalidate(route)
                            ConnectProbeResult.RetryShort
                        }
                        503 -> {
                            LOG.info("Pomerium unavailable during preflight, retrying...")
                            ConnectProbeResult.RetryLong
                        }
                        else -> {
                            val body = response.body.getOrNull().use {
                                it?.asRawString(Charset.defaultCharset())
                            }
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
                is IOException -> LOG.debug("IO exception during pomerium tunneling")
                is ClosedSendChannelException, is CancellationException -> { /*Do nothing for this case*/
                }

                else -> LOG.error("Exception while tunneling traffic", e)
            }
        }
    }

    companion object {
        private val LOG = LoggerFactory.getLogger(PomeriumTunneler::class.java.name)
    }

    private data class ActiveTunnel(
        val port: Int,
        val job: Job,
        val references: AtomicInteger,
    )

    private enum class ConnectProbeResult {
        Ready,
        RetryShort,
        RetryLong,
    }
}

sealed class PomeriumTunnelException(message: String, cause: Throwable? = null) : Exception(message, cause)
class PomeriumUnavailableException(message: String, cause: Throwable? = null) : PomeriumTunnelException(message, cause)
class PomeriumAuthorizationException(message: String, cause: Throwable? = null) : PomeriumTunnelException(message, cause)
class PomeriumTunnelCreationException(message: String, cause: Throwable? = null) : PomeriumTunnelException(message, cause)
