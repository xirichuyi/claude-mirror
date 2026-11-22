package claudemirror.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
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

/** The colours of the desktop app's default light and dark themes, so both look like one product. */
class Palette(
    val dark: Boolean,
    val frame: Color, val card: Color, val popup: Color,
    val text: Color, val muted: Color, val dim: Color,
    val accent: Color, val accentFill: Color, val selection: Color,
    val line: Color,
    val error: Color, val warning: Color, val added: Color, val removed: Color,
    /** Keyword, built-in, string, number, comment, function, decorator, property. */
    val syntax: List<Color>,
)

private fun hex(value: Long) = Color(0xFF000000 or value)

private val Midnight = Palette(
    dark = true,
    frame = hex(0x15171C), card = hex(0x1B1E24), popup = hex(0x23272E),
    text = hex(0xD4D8DF), muted = hex(0x959CA8), dim = hex(0x656C78),
    accent = hex(0x78AEF2), accentFill = hex(0x3D6FC4), selection = hex(0x2C4468),
    line = hex(0x2C3038),
    error = hex(0xF07F7F), warning = hex(0xE2BA6A), added = hex(0x5FBFA0), removed = hex(0xEB7F6C),
    syntax = listOf<Long>(0xD7915C, 0x6DDAD6, 0x75B18B, 0xC28EC4, 0x7F8796, 0x6FB7F0, 0xE4CF7A, 0xF9AEB9).map(::hex),
)

private val Daylight = Palette(
    dark = false,
    frame = hex(0xF3F4F6), card = hex(0xFFFFFF), popup = hex(0xFFFFFF),
    text = hex(0x24272E), muted = hex(0x5C6370), dim = hex(0x9AA0AB),
    accent = hex(0x2B66D2), accentFill = hex(0x2B66D2), selection = hex(0xDCE8FB),
    line = hex(0xDFE2E7),
    error = hex(0xC2373A), warning = hex(0x9A6200), added = hex(0x16805F), removed = hex(0xC4432F),
    syntax = listOf<Long>(0xA43E3A, 0x156686, 0x1D691A, 0x58309D, 0x6B717D, 0x0A59CA, 0x574504, 0x7E2166).map(::hex),
)

private val LocalPalette = staticCompositionLocalOf { Daylight }

val palette: Palette
    @Composable @ReadOnlyComposable get() = LocalPalette.current

private fun Palette.scheme(): ColorScheme {
    val onAccent = if (dark) hex(0x0E1116) else Color.White
    val base = if (dark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = if (dark) accent else accentFill, onPrimary = onAccent,
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
    extraSmall = RoundedCornerShape(6.dp), small = RoundedCornerShape(8.dp), medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(16.dp), extraLarge = RoundedCornerShape(22.dp),
)

private val AppType = Typography().let { base ->
    base.copy(
        titleLarge = base.titleLarge.copy(fontSize = 19.sp, lineHeight = 24.sp),
        bodyLarge = base.bodyLarge.copy(fontSize = 15.sp, lineHeight = 22.sp, letterSpacing = 0.sp),
        bodyMedium = base.bodyMedium.copy(fontSize = 14.sp, lineHeight = 20.sp, letterSpacing = 0.sp),
        bodySmall = base.bodySmall.copy(fontSize = 12.5.sp, lineHeight = 17.sp, letterSpacing = 0.sp),
        labelLarge = base.labelLarge.copy(letterSpacing = 0.sp),
        labelMedium = base.labelMedium.copy(letterSpacing = 0.sp),
        labelSmall = base.labelSmall.copy(letterSpacing = 0.sp),
    )
}

val CodeStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 12.5.sp, lineHeight = 18.sp)

@Composable
fun MirrorTheme(content: @Composable () -> Unit) {
    val colors = if (isSystemInDarkTheme()) Midnight else Daylight
    CompositionLocalProvider(LocalPalette provides colors) {
        MaterialTheme(colorScheme = colors.scheme(), shapes = AppShapes, typography = AppType, content = content)
    }
}
