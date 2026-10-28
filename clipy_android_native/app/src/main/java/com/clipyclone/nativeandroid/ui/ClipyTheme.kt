// Values exported from ClipyTheme.build; do not replace with Compose defaults.
package com.clipyclone.nativeandroid.ui

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.activity.compose.LocalActivity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalDensity
import androidx.core.view.WindowCompat
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.font.*
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import com.clipyclone.nativeandroid.R

// The Android Flutter APK embeds only MaterialIcons; text resolves through the platform's sans-serif family.
private val clipyFont = FontFamily.SansSerif

private val lightColors = lightColorScheme(
    primary = Color(0xFF1262F3),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFE4EDFF),
    onPrimaryContainer = Color(0xFF0D306B),
    secondary = Color(0xFF585E72),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFEAF0F8),
    onSecondaryContainer = Color(0xFF414659),
    tertiary = Color(0xFF815600),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFFFF0D0),
    onTertiaryContainer = Color(0xFF553B0A),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF1A1B21),
    surfaceContainerLow = Color(0xFFEDF1F7),
    surfaceContainerHigh = Color(0xFFE5EAF2),
    surfaceContainer = Color(0xFFEEEDF4),
    surfaceContainerHighest = Color(0xFFE3E2E9),
    onSurfaceVariant = Color(0xFF45464F),
    outline = Color(0xFF757680),
    outlineVariant = Color(0xFFDCE2EC),
    error = Color(0xFFBA1A1A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF93000A),
    inverseSurface = Color(0xFF2F3036),
    inverseOnSurface = Color(0xFFF1F0F7),
    inversePrimary = Color(0xFFB3C5FF),
    background = Color(0xFFF4F6FA),
    onBackground = Color(0xFF1A1B21),
)
private val darkColors = darkColorScheme(
    primary = Color(0xFFABC7FF),
    onPrimary = Color(0xFF1A2E60),
    primaryContainer = Color(0xFF193967),
    onPrimaryContainer = Color(0xFFD6E4FF),
    secondary = Color(0xFFC1C6DD),
    onSecondary = Color(0xFF2A3042),
    secondaryContainer = Color(0xFF243145),
    onSecondaryContainer = Color(0xFFDDE1F9),
    tertiary = Color(0xFFF2C36B),
    onTertiary = Color(0xFF422741),
    tertiaryContainer = Color(0xFF473518),
    onTertiaryContainer = Color(0xFFFFE1A6),
    surface = Color(0xFF171C26),
    onSurface = Color(0xFFE3E2E9),
    surfaceContainerLow = Color(0xFF1D2533),
    surfaceContainerHigh = Color(0xFF293345),
    surfaceContainer = Color(0xFF1E1F25),
    surfaceContainerHighest = Color(0xFF33343A),
    onSurfaceVariant = Color(0xFFC5C6D0),
    outline = Color(0xFF8F909A),
    outlineVariant = Color(0xFF3E485A),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    inverseSurface = Color(0xFFE3E2E9),
    inverseOnSurface = Color(0xFF2F3036),
    inversePrimary = Color(0xFF4A5C92),
    background = Color(0xFF10141C),
    onBackground = Color(0xFFE3E2E9),
)
private val clipyTypography = Typography(
    headlineLarge = TextStyle(fontFamily = clipyFont, fontSize = 32.0.sp, fontWeight = FontWeight(800), letterSpacing = -1.1.sp, lineHeight = 40.0.sp, platformStyle = PlatformTextStyle(includeFontPadding = false), lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)),
    headlineMedium = TextStyle(fontFamily = clipyFont, fontSize = 28.0.sp, fontWeight = FontWeight(800), letterSpacing = -0.7.sp, lineHeight = 36.12.sp, platformStyle = PlatformTextStyle(includeFontPadding = false), lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)),
    titleLarge = TextStyle(fontFamily = clipyFont, fontSize = 22.0.sp, fontWeight = FontWeight(700), letterSpacing = 0.0.sp, lineHeight = 27.94.sp, platformStyle = PlatformTextStyle(includeFontPadding = false), lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)),
    titleMedium = TextStyle(fontFamily = clipyFont, fontSize = 16.0.sp, fontWeight = FontWeight(600), letterSpacing = 0.15.sp, lineHeight = 24.0.sp, platformStyle = PlatformTextStyle(includeFontPadding = false), lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)),
    titleSmall = TextStyle(fontFamily = clipyFont, fontSize = 14.0.sp, fontWeight = FontWeight(500), letterSpacing = 0.1.sp, lineHeight = 20.02.sp, platformStyle = PlatformTextStyle(includeFontPadding = false), lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)),
    bodyLarge = TextStyle(fontFamily = clipyFont, fontSize = 16.0.sp, fontWeight = FontWeight(400), letterSpacing = 0.5.sp, lineHeight = 24.0.sp, platformStyle = PlatformTextStyle(includeFontPadding = false), lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)),
    bodyMedium = TextStyle(fontFamily = clipyFont, fontSize = 14.0.sp, fontWeight = FontWeight(400), letterSpacing = 0.25.sp, lineHeight = 21.0.sp, platformStyle = PlatformTextStyle(includeFontPadding = false), lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)),
    bodySmall = TextStyle(fontFamily = clipyFont, fontSize = 12.0.sp, fontWeight = FontWeight(400), letterSpacing = 0.4.sp, lineHeight = 15.96.sp, platformStyle = PlatformTextStyle(includeFontPadding = false), lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)),
    labelLarge = TextStyle(fontFamily = clipyFont, fontSize = 14.0.sp, fontWeight = FontWeight(500), letterSpacing = 0.1.sp, lineHeight = 20.02.sp, platformStyle = PlatformTextStyle(includeFontPadding = false), lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)),
    labelMedium = TextStyle(fontFamily = clipyFont, fontSize = 12.0.sp, fontWeight = FontWeight(500), letterSpacing = 0.5.sp, lineHeight = 15.96.sp, platformStyle = PlatformTextStyle(includeFontPadding = false), lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)),
    labelSmall = TextStyle(fontFamily = clipyFont, fontSize = 11.0.sp, fontWeight = FontWeight(500), letterSpacing = 0.5.sp, lineHeight = 15.95.sp, platformStyle = PlatformTextStyle(includeFontPadding = false), lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)),
 )

@Composable
fun ClipyTheme(dark: Boolean, chinese: Boolean = false, content: @Composable () -> Unit) {
    val activity = LocalActivity.current
    val view = LocalView.current
    SideEffect {
        activity?.let {
            val legacyNavigation = android.os.Build.VERSION.SDK_INT < 35
            if (legacyNavigation) {
                @Suppress("DEPRECATION")
                it.window.navigationBarColor = android.graphics.Color.BLACK
            }
            WindowCompat.getInsetsController(it.window, view).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !legacyNavigation && !dark
            }
        }
    }
    val density = LocalDensity.current
    val typography = remember(chinese, density.fontScale, density.density) {
        val locale = LocaleList(Locale(if (chinese) "zh-CN" else "en-US"))
        fun adapt(style: TextStyle) = style.copy(
            localeList = locale, textDirection = TextDirection.Ltr,
            lineHeight = (style.lineHeight.value / style.fontSize.value).em,
            // Flutter scales the font, not its logical-pixel letter spacing.
            letterSpacing = with(density) { style.letterSpacing.value.dp.toSp() })
        clipyTypography.copy(headlineLarge = adapt(clipyTypography.headlineLarge), headlineMedium = adapt(clipyTypography.headlineMedium),
            titleLarge = adapt(clipyTypography.titleLarge), titleMedium = adapt(clipyTypography.titleMedium), titleSmall = adapt(clipyTypography.titleSmall),
            bodyLarge = adapt(clipyTypography.bodyLarge), bodyMedium = adapt(clipyTypography.bodyMedium), bodySmall = adapt(clipyTypography.bodySmall),
            labelLarge = adapt(clipyTypography.labelLarge), labelMedium = adapt(clipyTypography.labelMedium), labelSmall = adapt(clipyTypography.labelSmall))
    }
    MaterialTheme(colorScheme = if (dark) darkColors else lightColors,
        typography = typography) {
        CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr,
            LocalContentColor provides MaterialTheme.colorScheme.onSurface,
            LocalTextStyle provides typography.bodyMedium, content = content)
    }
}
