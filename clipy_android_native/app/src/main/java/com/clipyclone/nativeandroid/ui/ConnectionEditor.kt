package com.clipyclone.nativeandroid.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.clipyclone.nativeandroid.sync.SyncSettings
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Port of the existing sheet: validate the full form, save once, restart once in its owner. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionEditor(settings: SyncSettings, dismiss: () -> Unit,
                     save: suspend (String, Int) -> Boolean, message: (String) -> Unit) {
    val strings = LocalStrings.current
    val colors = MaterialTheme.colorScheme
    var name by rememberSaveable { mutableStateOf(settings.name) }
    var port by rememberSaveable { mutableStateOf(settings.port.toString()) }
    var validating by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = { !saving })
    val invalidName = validating && name.trim().isEmpty()
    val parsedPort = port.trim().toIntOrNull()
    val invalidPort = validating && (parsedPort == null || parsedPort !in 1..65535)
    BackHandler(saving && LocalPageActive.current) { }
    if (LocalPageActive.current) ModalBottomSheet(onDismissRequest = { if (!saving) dismiss() }, sheetState = sheet,
        scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = .54f), containerColor = colors.surface, shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)) {
        ClipyModalSystemBars()
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).imePadding().padding(start = 24.dp, end = 24.dp, bottom = 24.dp)) {
            ClipyHeadingText(strings.connectionSettings, MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(24.dp))
            ClipyTextField(name, { name = it }, strings.deviceNameForSync, enabled = !saving,
                error = if (invalidName) strings.nameRequired else null, imeAction = ImeAction.Next,
                modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(16.dp))
            ClipyTextField(port, { port = it }, strings.syncPort, enabled = !saving,
                error = if (invalidPort) strings.invalidPort else null, keyboard = KeyboardType.Number,
                modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(24.dp))
            Button(contentPadding = clipyButtonPadding(icon = true), onClick = {
                validating = true
                val number = port.trim().toIntOrNull()
                if (name.trim().isNotEmpty() && number != null && number in 1..65535 && !saving) {
                    saving = true
                    scope.launch {
                        try {
                            val listening = save(name.trim(), number)
                            message(if (listening) strings.settingsSaved else strings.diagServerNotBound)
                            dismiss()
                        } catch (cancelled: CancellationException) { throw cancelled }
                        catch (_: Exception) { message(strings.operationFailed) }
                        finally { saving = false }
                    }
                }
            }, enabled = !saving, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), shape = RoundedCornerShape(16.dp)) {
                if (saving) ClipySpinner(Modifier.size(18.dp), strokeWidth = 2.dp)
                else ClipyButtonIcon(ClipyIcons.check_rounded)
                Spacer(Modifier.width(clipyButtonSpacing())); Text(strings.save)
            }
        }
    }
}
