package pomerium

import io.ktor.network.selector.*
import io.ktor.network.sockets.*
import io.ktor.util.network.*
import io.ktor.utils.io.*
import io.ktor.utils.io.jvm.javaio.*
import kotlinx.coroutines.*
import org.apache.http.client.methods.HttpGet
import org.apache.http.impl.client.HttpClients
import rawhttp.core.*
import rawhttp.core.body.EagerBodyReader
import toolbox.auth.PomeriumAuthProvider
import kotlin.random.Random

class MockPomerium(
    private val connectStatusCode: Int = 200,
    private val connectReason: String = if (connectStatusCode == 200) "OK" else "Service Unavailable",
    private val connectResponseBody: String? = if (connectStatusCode == 200) null else "<html>Service Unavailable</html>",
) {
    val token = Random.nextDouble().toString()
    val route = "localhost:2801"
    var requestCount = 0

    private var pomeriumTask: Deferred<*>? = null
    private val coroutineScope = CoroutineScope(Dispatchers.Default)
    private var socketConnection: Deferred<*>? = null

    suspend fun killConnection() {
        this.socketConnection?.cancelAndJoin()
    }

    suspend fun startMockPomerium(): Int {
        val selectorManager = SelectorManager(Dispatchers.IO)
        val socket = aSocket(selectorManager).tcp().bind("127.0.0.1", 0)
        pomeriumTask = coroutineScope.async(Dispatchers.IO) {
            while (isActive) {
                try {
                    val connection = socket.accept()
                    socketConnection = async {
                        connection.use { _ ->
                            val readChannel = connection.openReadChannel()
                            val writeChannel = connection.openWriteChannel(true)
                            val request = RawHttp().parseRequest(readChannel.toInputStream())

                            if (request.uri.path == PomeriumAuthProvider.POMERIUM_LOGIN_ENDPOINT) {
                                // This is a hack, it assumes the server is listening for the jwt response
                                // which is typically initiated by a browser, but this is a way to prevent
                                // a browser dependency in tests
                                val query = request.uri.query ?: ""
                                val redirect = query.split("&").firstOrNull {
                                    it.startsWith(PomeriumAuthProvider.POMERIUM_LOGIN_REDIRECT_PARAM)
                                }?.split("=")?.getOrNull(1)

                                if (redirect != null) {
                                    HttpClients.createSystem()
                                        .execute(HttpGet(redirect + "/?${PomeriumAuthProvider.POMERIUM_JWT_QUERY_PARAM}=$token"))
                                        .use {
                                            if (it.statusLine.statusCode != 200) {
                                                // Log or handle error? For mock it's fine
                                            }
                                        }
                                }

                                //This would be the response expected
                                val response = RawHttpResponse(
                                    null, null,
                                    StatusLine(HttpVersion.HTTP_1_1, 200, "OK"),
                                    RawHttpHeaders.empty(),
                                    EagerBodyReader("http://auth.example.com".encodeToByteArray())
                                )
                                response.writeTo(writeChannel.toOutputStream())
                            } else {
                                val auth = request.headers.get("authorization").firstOrNull()
                                // In production mock we might just want to be more lenient or throw IllegalStateException
                                if (auth != "Pomerium $token") {
                                    // Handle mismatch
                                }

                                val response = RawHttpResponse(
                                    null, null,
                                    StatusLine(HttpVersion.HTTP_1_1, connectStatusCode, connectReason),
                                    RawHttpHeaders.empty(),
                                    connectResponseBody?.let { EagerBodyReader(it.encodeToByteArray()) }
                                )
                                response.writeTo(writeChannel.toOutputStream())
                                requestCount++
                                if (connectStatusCode == 200) {
                                    readChannel.joinTo(writeChannel, true)
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    //do nothing
                }
            }
        }
        pomeriumTask!!.invokeOnCompletion {
            socket.close()
            selectorManager.close()
        }
        return socket.localAddress.toJavaAddress().port
    }

    fun stop() {
        if (pomeriumTask != null) {
            runBlocking {
                pomeriumTask!!.cancelAndJoin()
                pomeriumTask = null
            }
        }
        coroutineScope.cancel()
    }
}
