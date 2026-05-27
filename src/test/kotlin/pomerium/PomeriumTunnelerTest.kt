package pomerium

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions
import org.junit.jupiter.api.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.doReturn
import org.mockito.kotlin.doSuspendableAnswer
import org.mockito.kotlin.mock
import toolbox.auth.AuthProvider
import toolbox.auth.PomeriumTunneler
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URI
import kotlin.random.Random

class PomeriumTunnelerTest {
    @JvmField
    val mockPomerium = MockPomerium()

    @AfterEach
    fun teardown() {
        mockPomerium.stop()
    }

    @Test
    fun `test end to end tunneler`() = runTest {
        val authProvider = mock<AuthProvider> {
            onBlocking { getAuth(any(), any()) } doReturn CompletableDeferred(mockPomerium.token)
        }
        val pomeriumTunneler = PomeriumTunneler(authProvider, null,  100, null)
        pomeriumTunneler.use {
            val mockPomeriumPort = mockPomerium.startMockPomerium()

            val uri = URI("tcp://${mockPomerium.route}")
            val port = pomeriumTunneler.startTunnel(uri, authScope = backgroundScope, pomeriumPort = mockPomeriumPort, useTls = !uri.scheme.equals("tcp", ignoreCase = true))
            Socket("localhost", port).use {
                val testEchoMessage = Random.nextBytes(1024)
                it.getOutputStream().write(testEchoMessage)
                val ips = it.getInputStream()
                val line = ips.readNBytes(1024)
                Assertions.assertEquals(0, ips.available())
                Assertions.assertArrayEquals(testEchoMessage, line)
            }
        }
    }

    @Test
    fun `test tunneler with reconnect`() = runTest {
        val authProvider = mock<AuthProvider> {
            onBlocking { getAuth(any(), any()) } doReturn CompletableDeferred(mockPomerium.token)
        }
        val pomeriumTunneler = PomeriumTunneler(authProvider, null, 100, null)
        val mockPomeriumPort = mockPomerium.startMockPomerium()

        val uri = URI("tcp://${mockPomerium.route}")
        val port = pomeriumTunneler.startTunnel(uri, authScope = backgroundScope, pomeriumPort = mockPomeriumPort, useTls = !uri.scheme.equals("tcp", ignoreCase = true))
        Socket("localhost", port).use {
            val testEchoMessage = Random.nextBytes(1024)
            it.getOutputStream().write(testEchoMessage)
            val ips = it.getInputStream()
            ips.readNBytes(102)
        }
        Socket("localhost", port).use {
            val testEchoMessage = Random.nextBytes(1024)
            it.getOutputStream().write(testEchoMessage)
            val ips = it.getInputStream()
            val line = ips.readNBytes(1024)
            Assertions.assertEquals(0, ips.available())
            Assertions.assertArrayEquals(testEchoMessage, line)
        }
    }

    @Test
    fun `test tunneler with pomerium disconnect`() = runTest {
        val authProvider = mock<AuthProvider> {
            onBlocking { getAuth(any(), any()) } doReturn CompletableDeferred(mockPomerium.token)
        }
        val pomeriumTunneler = PomeriumTunneler(authProvider, null, 500, null)
        val mockPomeriumPort = mockPomerium.startMockPomerium()

        val uri = URI("tcp://${mockPomerium.route}")
        val port = pomeriumTunneler.startTunnel(uri, authScope = backgroundScope, pomeriumPort = mockPomeriumPort, useTls = !uri.scheme.equals("tcp", ignoreCase = true))
        try {
            Socket("localhost", port).use {
                it.soTimeout = 500
                val testEchoMessage = Random.nextBytes(1024)
                it.getOutputStream().write(testEchoMessage)
                val ips = it.getInputStream()
                val line = ips.readNBytes(1024)
                Assertions.assertEquals(0, ips.available())
                Assertions.assertArrayEquals(testEchoMessage, line)

                mockPomerium.killConnection()

                val testEchoMessage2 = Random.nextBytes(1024)
                it.getOutputStream().write(testEchoMessage2)
                ips.readNBytes(1024)
            }
        } catch (e: SocketTimeoutException) {
            //expected
        }
        Assertions.assertEquals(1, mockPomerium.requestCount)
        Socket("localhost", port).use {
            val testEchoMessage = Random.nextBytes(1024)
            it.getOutputStream().write(testEchoMessage)
            val ips = it.getInputStream()
            val line = ips.readNBytes(1024)
            Assertions.assertEquals(0, ips.available())
            Assertions.assertArrayEquals(testEchoMessage, line)
        }
        Assertions.assertEquals(2, mockPomerium.requestCount)
    }


    @Test
    fun `test tunneler with auth blocked waiting`() = runTest {
        var authCount = 0
        val job = async(Dispatchers.Default) {
            while (authCount <= 1) {
                delay(10)
            }
            return@async mockPomerium.token
        }
        val authProvider = mock<AuthProvider> {
            onBlocking { getAuth(any(), any()) } doReturn CompletableDeferred("") doSuspendableAnswer {
                ++authCount
                job
            }
        }
        val pomeriumTunneler = PomeriumTunneler(authProvider,null,  200, null)
        val mockPomeriumPort = mockPomerium.startMockPomerium()

        val uri = URI("tcp://${mockPomerium.route}")
        val port = pomeriumTunneler.startTunnel(uri, authScope = backgroundScope, pomeriumPort = mockPomeriumPort, useTls = !uri.scheme.equals("tcp", ignoreCase = true))
        try {
            Socket("localhost", port).use {
                it.soTimeout = 100
                val testEchoMessage = Random.nextBytes(1024)
                it.getOutputStream().write(testEchoMessage)
                val ips = it.getInputStream()
                val line = ips.readNBytes(1024)
                Assertions.assertEquals(0, ips.available())
                Assertions.assertArrayEquals(testEchoMessage, line)
            }
        } catch (e: SocketTimeoutException) {
            //Expected
        }

        Thread.sleep(100) //Ensure we wait the timeout

        Socket("localhost", port).use {
            val testEchoMessage = Random.nextBytes(1024)
            it.getOutputStream().write(testEchoMessage)
            val ips = it.getInputStream()
            val line = ips.readNBytes(1024)
            Assertions.assertEquals(0, ips.available())
            Assertions.assertArrayEquals(testEchoMessage, line)
        }

        //The WithTimeout should prevent
        Assertions.assertEquals(1, mockPomerium.requestCount)
    }

    @Test
    fun `test tunneler with auth blocked waiting closes connection on timeout`() = runTest {
        var authCount = 0

        val authProvider = mock<AuthProvider> {
            onBlocking { getAuth(any(), any()) } doReturn CompletableDeferred("") doSuspendableAnswer {
                async {
                    delay(200)
                    return@async ""
                }
            }
        }
        val pomeriumTunneler = PomeriumTunneler(authProvider, null,  100, null)
        val mockPomeriumPort = mockPomerium.startMockPomerium()

        val uri = URI("tcp://${mockPomerium.route}")
        val port = pomeriumTunneler.startTunnel(uri, authScope = backgroundScope, pomeriumPort = mockPomeriumPort, useTls = !uri.scheme.equals("tcp", ignoreCase = true))
        try {
            Socket("localhost", port).use {
                it.soTimeout = 200
                val testEchoMessage = Random.nextBytes(1024)
                it.getOutputStream().write(testEchoMessage)
                val ips = it.getInputStream()
                val line = ips.readNBytes(1024)
                Assertions.assertEquals(0, ips.available())
                Assertions.assertArrayEquals(testEchoMessage, line)
            }
        } catch (e: SocketException) {
            Assertions.assertTrue(e.message?.contains("Connection reset") ?: false)
            //Expected
        }
    }

    @Test
    fun `test tunneler with lifetime termination`() = runTest {
        val authProvider = mock<AuthProvider> {
            onBlocking { getAuth(any(), any()) } doReturn CompletableDeferred(mockPomerium.token)
        }
        val pomeriumTunneler = PomeriumTunneler(authProvider, null,  100, null)
        val mockPomeriumPort = mockPomerium.startMockPomerium()

        val uri = URI("tcp://${mockPomerium.route}")
        val port = pomeriumTunneler.startTunnel(uri, authScope = backgroundScope, pomeriumPort = mockPomeriumPort, useTls = !uri.scheme.equals("tcp", ignoreCase = true))
        Socket("localhost", port).use {
            val testEchoMessage = Random.nextBytes(1024)
            it.getOutputStream().write(testEchoMessage)
            val ips = it.getInputStream()
            val line = ips.readNBytes(1024)
            Assertions.assertEquals(0, ips.available())
            Assertions.assertArrayEquals(testEchoMessage, line)
        }

        Thread.sleep(100)
        Assertions.assertFalse(pomeriumTunneler.isTunneling())
    }
}
