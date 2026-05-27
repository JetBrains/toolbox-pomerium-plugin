package toolbox.auth

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import java.net.URI

interface AuthProvider {
    suspend fun getAuth(route: URI, scope: CoroutineScope): Deferred<String>
    suspend fun invalidate(route: URI)
}
