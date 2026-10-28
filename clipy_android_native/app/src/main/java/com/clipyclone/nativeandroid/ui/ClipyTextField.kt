package com.clipyclone.nativeandroid.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.*
import androidx.compose.ui.unit.dp

/** Flutter outline geometry: 18dp content + 4dp gap inset; no reserved 8dp label slot. */
@Composable
internal fun ClipyTextField(value: String, change: (String) -> Unit, label: String, enabled: Boolean = true,
    helper: String? = null, secret: Boolean = false, lines: Int = 1, keyboard: KeyboardType = KeyboardType.Text,
    wrap: Boolean = false, hint: String? = null, error: String? = null, autofocus: Boolean = false,
    imeAction: ImeAction = ImeAction.Default, submit: (() -> Unit)? = null, modifier: Modifier = Modifier, maximumLines: Int? = null) {
    val colors = MaterialTheme.colorScheme
    val focus = remember { FocusRequester() }
    val interactions = remember { MutableInteractionSource() }
    val focused by interactions.collectIsFocusedAsState()
    val keyboardController = LocalSoftwareKeyboardController.current
    val active = LocalPageActive.current
    val floating = label.isNotEmpty() && (focused || value.isNotEmpty())
    val shape = RoundedCornerShape(18.dp)
    val foreground = if (enabled) colors.onSurface else colors.onSurface.copy(alpha = .38f)
    val labelColor = if (!enabled) colors.onSurface.copy(alpha = .38f) else if (error != null) colors.error else if (focused) colors.primary else colors.onSurfaceVariant
    LaunchedEffect(autofocus, active) { if (autofocus && active) { focus.requestFocus(); keyboardController?.show() } }
    Column(modifier.fillMaxWidth()) {
        Box(Modifier.fillMaxWidth()) {
            BasicTextField(value, change, enabled = enabled,
                modifier = Modifier.fillMaxWidth().focusRequester(focus).semantics { contentDescription = label },
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = foreground),
                cursorBrush = SolidColor(colors.primary), interactionSource = interactions,
                minLines = lines, maxLines = if (secret || (!wrap && lines == 1)) 1 else maximumLines ?: if (lines > 1) 5 else Int.MAX_VALUE,
                singleLine = secret || (!wrap && lines == 1),
                visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
                keyboardOptions = KeyboardOptions(keyboardType = if (secret) KeyboardType.Password else keyboard,
                    autoCorrectEnabled = false, imeAction = if (submit != null) ImeAction.Done else imeAction),
                keyboardActions = KeyboardActions(onDone = { submit?.invoke() }),
                decorationBox = { inner ->
                    Box(Modifier.fillMaxWidth().heightIn(min = 56.dp)
                        .background(colors.surfaceContainerLow, shape)
                        .then(if (focused || error != null) Modifier.border(if (focused) 1.5.dp else 1.dp, labelColor, shape) else Modifier)
                        .padding(horizontal = 22.dp, vertical = 16.dp), contentAlignment = Alignment.TopStart) {
                        if (!floating && label.isNotEmpty()) Text(label, style = MaterialTheme.typography.bodyLarge, color = labelColor)
                        else if (value.isEmpty() && hint != null) Text(hint, style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
                        inner()
                    }
                })
            if (floating) Text(label, Modifier.padding(start = 22.dp).offset(y = (-8).dp),
                style = MaterialTheme.typography.bodySmall, color = labelColor)
        }
        (error ?: helper)?.let {
            Text(it, Modifier.padding(start = 22.dp, end = 22.dp, top = 4.dp),
                style = MaterialTheme.typography.bodySmall, maxLines = 6,
                color = if (error != null) colors.error else colors.onSurfaceVariant)
        }
    }
}
