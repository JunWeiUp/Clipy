package com.clipyclone.nativeandroid.ui

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.clipyclone.nativeandroid.relay.NativeRelayController
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

internal fun relayText(zh: Boolean, chinese: String, english: String) = if (zh) chinese else english

@Composable
fun RelaySettingsPanel(controller: NativeRelayController, openGroups: () -> Unit, message: (String) -> Unit) {
    val state by controller.state.collectAsStateWithLifecycle()
    val zh = LocalStrings.current.chinese
    val active = LocalPageActive.current
    val scope = rememberCoroutineScope(); val context = LocalContext.current; val colors = MaterialTheme.colorScheme
    var url by rememberSaveable { mutableStateOf("") }; var device by rememberSaveable { mutableStateOf("") }
    // Access credentials are deliberately not written into saved-instance state.
    var accessKey by remember { mutableStateOf("") }; var enrollment by remember { mutableStateOf("") }
    var enabled by rememberSaveable { mutableStateOf(false) }; var expanded by rememberSaveable { mutableStateOf(false) }
    var loaded by remember { mutableStateOf(false) }; var error by remember { mutableStateOf<String?>(null) }
    var publicInfo by remember { mutableStateOf<String?>(null) }
    var lastConfiguration by remember { mutableStateOf<Triple<Boolean, String, String>?>(null) }
    LaunchedEffect(controller, active) {
        if (active) try { controller.loadSettings() }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { error = relayText(zh, "读取配置失败，请重新打开此页面。", "Could not load settings. Reopen this page.") }
    }
    LaunchedEffect(state.settingsLoaded, state.enabled, state.url, state.deviceId) {
        if (state.settingsLoaded) {
            val next = Triple(state.enabled, state.url, state.deviceId)
            if (!loaded || lastConfiguration != next) {
                enabled = state.enabled; url = state.url; device = state.deviceId; loaded = true; lastConfiguration = next
            }
        }
    }
    Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
        Text(relayText(zh, "公网中继", "Internet relay"), Modifier.padding(horizontal = 4.dp), style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(4.dp))
        Text(relayText(zh, "设备 ID 和公网 Key 分开保存；局域网无需配置中继。", "Keep device ID and Internet Key separate. LAN needs no relay setup."),
            Modifier.padding(start = 4.dp, end = 4.dp, bottom = 12.dp), style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
        Surface(shape = RoundedCornerShape(24.dp), color = colors.surface) {
            Column(Modifier.fillMaxWidth().padding(16.dp)) {
                Row(Modifier.fillMaxWidth().clickable(onClick = openGroups).heightIn(min = 72.dp), verticalAlignment = Alignment.CenterVertically) {
                    ClipyIcon(ClipyIcons.devices); Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text(relayText(zh, "管理公网设备组", "Manage relay device group"), style = MaterialTheme.typography.bodyLarge)
                        Text(relayText(zh, "查看设备、添加设备或扫码加入", "View devices, invite or scan to join"), style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
                    }
                    ClipyIcon(ClipyIcons.chevron_right_rounded)
                }
                Row(Modifier.fillMaxWidth().heightIn(min = 56.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(relayText(zh, "启用公网中继", "Enable Internet relay"), Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                    Switch(enabled, { enabled = it }, enabled = loaded && !state.settingsSaving)
                }
                RelayField(url, { url = it.replace("\n", "").replace("\r", "") }, relayText(zh, "中继地址", "Relay URL"), enabled = loaded && !state.settingsSaving, keyboard = KeyboardType.Uri, wrap = true, imeAction = ImeAction.Next)
                Spacer(Modifier.height(12.dp))
                RelayField(device, { device = it.replace("\n", "").replace("\r", "").take(80) }, relayText(zh, "设备 ID", "Device ID"),
                    helper = relayText(zh, "填写服务端登记的 ID；更换 Key 时无需修改。", "Use the registered ID. Keep it when replacing the key."), enabled = loaded && !state.settingsSaving, wrap = true, imeAction = ImeAction.Next)
                Spacer(Modifier.height(12.dp))
                RelayField(accessKey, { accessKey = it }, relayText(zh, "公网 Key", "Internet Key"), secret = true,
                    helper = if (state.configured) relayText(zh, "已保存，留空保持不变", "Saved; leave blank to keep") else null, enabled = loaded && !state.settingsSaving)
                Row(Modifier.fillMaxWidth().clickable { expanded = !expanded }.heightIn(min = 56.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(relayText(zh, "首次接入 / 更新信任配置", "Enrollment / trusted peers"), Modifier.weight(1f))
                    ClipyIcon(if (expanded) ClipyIcons.expand_less else ClipyIcons.expand_more)
                }
                if (expanded) Column(Modifier.padding(top = 4.dp, bottom = 12.dp)) {
                    TextButton(onClick = {
                        scope.launch {
                            try {
                                val info = controller.publicInfo(device)
                                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Clipy", info))
                                publicInfo = info
                            } catch (cancelled: CancellationException) { throw cancelled }
                            catch (_: Exception) { message(relayText(zh, "请先填写有效的设备 ID。", "Enter a valid device ID first.")) }
                        }
                    }, enabled = loaded && !state.settingsSaving) {
                        ClipyIcon(ClipyIcons.key, size = 18.dp, color = colors.primary); Spacer(Modifier.width(8.dp))
                        Text(relayText(zh, "复制本机公钥登记信息", "Copy device enrollment info"))
                    }
                    RelayField(enrollment, { enrollment = it }, relayText(zh, "本设备接入配置 JSON", "Device enrollment JSON"), secret = true,
                        helper = relayText(zh, "首次接入时导入；仅换 Key 无需重复填写。", "Import once. Not needed when only replacing the key."), enabled = loaded && !state.settingsSaving)
                }
                error?.let { Text(it, Modifier.padding(vertical = 8.dp), color = colors.error) }
                Spacer(Modifier.height(12.dp))
                RelayFilledButton(relayText(zh, if (state.settingsSaving) "正在保存…" else "保存中继设置", if (state.settingsSaving) "Saving…" else "Save relay settings"),
                    enabled = loaded && !state.settingsSaving, modifier = Modifier.fillMaxWidth()) {
                    error = null
                    scope.launch {
                        try {
                            controller.saveSettings(enabled, url, device, accessKey, enrollment)
                            accessKey = ""; enrollment = ""
                            message(relayText(zh, "设置已保存", "Settings saved"))
                        } catch (cancelled: CancellationException) { throw cancelled }
                        catch (failure: Exception) {
                            error = if (failure.message?.contains("enrollmentRequired") == true)
                                relayText(zh, "首次配置请先导入本设备接入配置，之后可单独更换公网 Key。", "Import device enrollment once; then the Internet Key can be replaced separately.")
                            else relayText(zh, "保存失败，请检查设备 ID、WSS 地址、Key 和接入配置是否匹配。", "Could not save. Check the device ID, WSS URL, key and enrollment configuration.")
                        }
                    }
                }
            }
        }
    }
    if (active) publicInfo?.let { info ->
        AlertDialog(onDismissRequest = { publicInfo = null }, containerColor = colors.surface, shape = RoundedCornerShape(24.dp),
            title = { Text(relayText(zh, "本机公钥登记信息", "Device enrollment information")) }, text = { SelectionContainer { Text(info) } },
            confirmButton = { TextButton(onClick = { publicInfo = null }) { Text(relayText(zh, "关闭", "Close")) } })
    }
}

@Composable internal fun RelayField(value: String, change: (String) -> Unit, label: String, enabled: Boolean = true,
                                   helper: String? = null, secret: Boolean = false, lines: Int = 1, keyboard: KeyboardType = KeyboardType.Text, wrap: Boolean = false,
                                   hint: String? = null, error: String? = null, autofocus: Boolean = false, imeAction: ImeAction = ImeAction.Default,
                                   submit: (() -> Unit)? = null) {
    ClipyTextField(value, change, label, enabled, helper, secret, lines, keyboard, wrap,
        hint, error, autofocus, imeAction, submit)
}

@Composable internal fun RelayFilledButton(text: String, enabled: Boolean = true, modifier: Modifier = Modifier, destructive: Boolean = false, icon: Int? = null, click: () -> Unit) {
    Button(click, enabled = enabled, modifier = modifier.heightIn(min = 48.dp), shape = RoundedCornerShape(16.dp), contentPadding = clipyButtonPadding(icon != null),
        colors = ButtonDefaults.buttonColors(containerColor = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)) {
        if (icon != null) { ClipyButtonIcon(icon); Spacer(Modifier.width(clipyButtonSpacing())) }
        Text(text)
    }
}
