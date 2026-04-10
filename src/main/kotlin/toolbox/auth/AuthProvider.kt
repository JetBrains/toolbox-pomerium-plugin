package toolbox.auth

import kotlinx.coroutines.Deferred
import java.net.URI

interface AuthProvider {
    suspend fun getAuth(route: URI): Deferred<String>
    suspend fun invalidate(route: URI)
}