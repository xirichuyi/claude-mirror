package claudemirror.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Warm paper and clay, after Claude's own apps: the phone reads as a Claude product, in light and in dark. */
class Palette(
    val dark: Boolean,
    val frame: Color, val card: Color, val popup: Color,
    val text: Color, val muted: Color, val dim: Color,
    val accent: Color, val accentFill: Color,
    /** What the user said, and whatever else is set apart from the page without being a card. */
    val selection: Color,
    val line: Color,
    val error: Color, val warning: Color, val added: Color, val removed: Color,
    /** Keyword, built-in, string, number, comment, function, decorator, property. */
    val syntax: List<Color>,
)

private fun hex(value: Long) = Color(0xFF000000 or value)

private val Midnight = Palette(
    dark = true,
    frame = hex(0x262624), card = hex(0x30302E), popup = hex(0x30302E),
    text = hex(0xF0EEE6), muted = hex(0xA6A39A), dim = hex(0x85827A),
    accent = hex(0xDE8262), accentFill = hex(0xB8573A), selection = hex(0x141413),
    line = hex(0x3E3D3A),
    error = hex(0xE5786B), warning = hex(0xD9A84E), added = hex(0x7FB58B), removed = hex(0xE5786B),
    syntax = listOf<Long>(0xD99A6C, 0x7CC7C2, 0x9DBF86, 0xC49BC9, 0x8A887F, 0x86B6E8, 0xDCC27A, 0xE5A9A0).map(::hex),
)

private val Daylight = Palette(
    dark = false,
    frame = hex(0xFAF9F5), card = hex(0xFFFFFF), popup = hex(0xFFFFFF),
    text = hex(0x1F1E1D), muted = hex(0x6B6A65), dim = hex(0x87857D),
    accent = hex(0xAD4E2B), accentFill = hex(0xB8573A), selection = hex(0xF0EEE6),
    line = hex(0xE5E3DA),
    error = hex(0xB5443A), warning = hex(0x8F6400), added = hex(0x2F7D4F), removed = hex(0xB5443A),
    syntax = listOf<Long>(0xA4502D, 0x1F6F78, 0x3B6E23, 0x7A3E92, 0x7D7B73, 0x2A5FA8, 0x6B5200, 0x8A3552).map(::hex),
)

private val LocalPalette = staticCompositionLocalOf { Daylight }

val palette: Palette
    @Composable @ReadOnlyComposable get() = LocalPalette.current

/** A filled button. Its colour is darker than the accent used for words, so that white reads on it. */
@Composable
fun fillColors() = ButtonDefaults.buttonColors(containerColor = palette.accentFill, contentColor = Color.White)

private fun Palette.scheme(): ColorScheme {
    val onAccent = Color.White
    val base = if (dark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = accent, onPrimary = if (dark) frame else onAccent,
        primaryContainer = selection, onPrimaryContainer = text,
        secondary = accent, onSecondary = onAccent, secondaryContainer = selection, onSecondaryContainer = text,
        tertiary = warning, onTertiary = onAccent,
        tertiaryContainer = warning.copy(alpha = 0.16f).compositeOver(frame), onTertiaryContainer = text,
        background = frame, onBackground = text,
        surface = frame, onSurface = text, surfaceVariant = card, onSurfaceVariant = muted,
        surfaceTint = Color.Transparent, surfaceBright = popup, surfaceDim = frame,
        surfaceContainerLowest = frame, surfaceContainerLow = card, surfaceContainer = card,
        surfaceContainerHigh = popup, surfaceContainerHighest = popup,
        inverseSurface = text, inverseOnSurface = frame, inversePrimary = accentFill,
        error = error, onError = onAccent,
        errorContainer = error.copy(alpha = 0.14f).compositeOver(frame), onErrorContainer = text,
        outline = dim, outlineVariant = line, scrim = Color.Black,
    )
}

private fun Color.compositeOver(background: Color) = Color(
    red = red * alpha + background.red * (1 - alpha),
    green = green * alpha + background.green * (1 - alpha),
    blue = blue * alpha + background.blue * (1 - alpha),
)

private val AppShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp), small = RoundedCornerShape(10.dp), medium = RoundedCornerShape(14.dp),
    large = RoundedCornerShape(20.dp), extraLarge = RoundedCornerShape(26.dp),
)

private val AppType = Typography().let { base ->
    base.copy(
        titleLarge = base.titleLarge.copy(fontFamily = FontFamily.Serif, fontSize = 20.sp, lineHeight = 26.sp),
        titleMedium = base.titleMedium.copy(fontSize = 16.sp, lineHeight = 22.sp, letterSpacing = 0.sp),
        bodyLarge = base.bodyLarge.copy(fontSize = 15.sp, lineHeight = 22.sp, letterSpacing = 0.sp),
        bodyMedium = base.bodyMedium.copy(fontSize = 14.sp, lineHeight = 20.sp, letterSpacing = 0.sp),
        bodySmall = base.bodySmall.copy(fontSize = 12.5.sp, lineHeight = 17.sp, letterSpacing = 0.sp),
        labelLarge = base.labelLarge.copy(letterSpacing = 0.sp),
        labelMedium = base.labelMedium.copy(letterSpacing = 0.sp),
        labelSmall = base.labelSmall.copy(letterSpacing = 0.sp),
    )
}

/** What Claude writes is set in a serif face, as in its own apps; what the user and the app say is not. */
val ProseStyle = TextStyle(fontFamily = FontFamily.Serif, fontSize = 16.sp, lineHeight = 25.sp)

val CodeStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 12.5.sp, lineHeight = 18.sp)

@Composable
fun MirrorTheme(content: @Composable () -> Unit) {
    val colors = if (isSystemInDarkTheme()) Midnight else Daylight
    CompositionLocalProvider(LocalPalette provides colors) {
        MaterialTheme(colorScheme = colors.scheme(), shapes = AppShapes, typography = AppType, content = content)
    }
}
