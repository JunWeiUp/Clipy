package com.clipyclone.nativeandroid.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.content.res.ResourcesCompat
import com.clipyclone.nativeandroid.R

@Composable
fun ClipyIcon(glyph: Int, modifier: Modifier = Modifier, size: Dp = 24.dp,
              color: Color = MaterialTheme.colorScheme.onSurfaceVariant, description: String? = null) {
    val context = LocalContext.current
    val typeface = remember(context) { ResourcesCompat.getFont(context, R.font.material_icons) }
    val paint = remember { android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG) }
    Canvas(modifier.size(size).then(if (description == null) Modifier else Modifier.semantics { contentDescription = description })) {
        paint.typeface = typeface; paint.color = color.toArgb(); paint.textSize = size.toPx()
        paint.textAlign = android.graphics.Paint.Align.CENTER
        drawContext.canvas.nativeCanvas.drawText(String(Character.toChars(glyph)), this.size.width / 2,
            this.size.height / 2 - (paint.ascent() + paint.descent()) / 2, paint)
    }
}

@Composable
fun ClipyIconTile(glyph: Int, size: Dp = 44.dp) {
    Box(Modifier.size(size).background(MaterialTheme.colorScheme.primaryContainer.copy(alpha = .65f),
        RoundedCornerShape(size * .32f)), contentAlignment = Alignment.Center) {
        ClipyIcon(glyph, size = size * .5f, color = MaterialTheme.colorScheme.primary)
    }
}
