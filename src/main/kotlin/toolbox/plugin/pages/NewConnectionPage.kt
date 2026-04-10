package toolbox.plugin.pages

import com.jetbrains.toolbox.api.core.ui.icons.SvgIcon
import com.jetbrains.toolbox.api.localization.LocalizableString
import com.jetbrains.toolbox.api.localization.LocalizableStringFactory
import com.jetbrains.toolbox.api.ui.actions.RunnableActionDescription
import com.jetbrains.toolbox.api.ui.components.TextField
import com.jetbrains.toolbox.api.ui.components.TextFieldMutable
import com.jetbrains.toolbox.api.ui.components.UiField
import com.jetbrains.toolbox.api.ui.components.UiPage
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import toolbox.auth.PomeriumTunneler
import kotlin.random.Random

class NewConnectionPage(tunneler: PomeriumTunneler, i18n: LocalizableStringFactory, title: LocalizableString) : UiPage(
    MutableStateFlow(title)
) {
    val nameField: TextFieldMutable =
        TextField(i18n.ptrl("name"), "", placeholder = i18n.ptrl("Name for ide connection "))

    val urlField: TextFieldMutable =
        TextField(i18n.ptrl("URL"), "", placeholder = i18n.ptrl("Url for ide connection "))
    val agentField: TextFieldMutable =
        TextField(i18n.ptrl("Agent URL"), "", placeholder = i18n.ptrl("Url for toolbox agent connection "))


    override val fields: StateFlow<List<UiField>> = MutableStateFlow(
        listOf(
            nameField,
            urlField,
            agentField
        )
    )

    private val connectAction = object : RunnableActionDescription {
        /*override fun validate(): Boolean {
            val userAndHostValue = urlField.contentState.value
            if (userAndHostValue.isEmpty()) {
                updateValidationError()
                return false
            }
            updateValidationError()
            return false
        }*/

        override fun run() {
            createEnvironment()
        }

        private fun createEnvironment() {
            val url = urlField.contentState.value
            val name = nameField.contentState.value.ifBlank {  Random.nextLong().toString()}
            val agentUrl = agentField.contentState.value
            fun getUrl(): String {
                return agentUrl
            }
          //  val environment = PomeriumEnvironment(name, url, tunneler, logger, i18n, scope )
            //environment.connectionRequest.tryEmit(true)
        }

        override val label = i18n.ptrl("Connect")
    }

    override val actionButtons: StateFlow<List<RunnableActionDescription>> =
        MutableStateFlow(
            listOf(connectAction)
        )


    override val svgIcon: SvgIcon? = null
}