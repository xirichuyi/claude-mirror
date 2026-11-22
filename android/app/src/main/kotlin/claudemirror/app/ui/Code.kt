package claudemirror.app.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import claudemirror.core.DiffLine
import kotlinx.coroutines.delay

private val Keywords = setOf(
    "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "def", "default", "defer", "del", "do", "done",
    "elif", "else", "enum", "esac", "except", "export", "extends", "extern", "fi", "final", "finally", "fn", "for", "from", "fun", "func",
    "function", "go", "if", "impl", "implements", "import", "in", "interface", "is", "lambda", "let", "loop", "match", "mod", "mut", "namespace",
    "new", "not", "object", "of", "override", "package", "pass", "private", "protected", "pub", "public", "raise", "return", "select", "static",
    "struct", "super", "switch", "then", "throw", "trait", "try", "type", "typealias", "typeof", "use", "val", "var", "void", "when", "where",
    "while", "with", "yield",
)
private val Literals = setOf("true", "false", "null", "nil", "None", "True", "False", "undefined", "this", "self")
private val HashComments = setOf("sh", "bash", "zsh", "shell", "console", "python", "py", "ruby", "rb", "yaml", "yml", "toml", "dockerfile", "makefile", "perl", "r", "ini", "conf", "nginx", "")
private val Tokens = Regex(
    """(?<comment>//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*)|(?<string>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`)|(?<number>\b\d[\w.]*\b)|(?<call>\b[A-Za-z_]\w*(?=\())|(?<word>\b[A-Za-z_]\w*\b)""",
)

/** Colours the parts of source text every language has in common: comments, strings, numbers, keywords and calls. */
fun highlight(code: String, language: String?, colors: Palette): AnnotatedString {
    val name = language.orEmpty().lowercase()
    // A long file is shown plain rather than holding up the reply it is part of.
    if (code.length > 40_000 || name in setOf("text", "txt", "plain", "output")) return AnnotatedString(code)
    if (name == "diff" || name == "patch") return buildAnnotatedString {
        code.lineSequence().forEachIndexed { index, line ->
            if (index > 0) append('\n')
            val color = when { line.startsWith("+") -> colors.added; line.startsWith("-") -> colors.removed; line.startsWith("@@") -> colors.syntax[5]; else -> Color.Unspecified }
            withStyle(SpanStyle(color = color)) { append(line) }
        }
    }
    val (keyword, builtin, string, number, comment, function) = colors.syntax
    return buildAnnotatedString {
        append(code)
        for (match in Tokens.findAll(code)) {
            val text = match.value
            val color = when {
                match.groups["comment"] != null -> if (text.startsWith("#") && name !in HashComments) continue else comment
                match.groups["string"] != null -> string
                match.groups["number"] != null -> number
                match.groups["call"] != null -> if (text in Keywords) keyword else function
                text in Keywords -> keyword
                text in Literals -> builtin
                else -> continue
            }
            addStyle(SpanStyle(color = color), match.range.first, match.range.last + 1)
        }
    }
}

private operator fun <T> List<T>.component6(): T = this[5]

@Composable
fun CopyButton(text: String, modifier: Modifier = Modifier) {
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { delay(1500); copied = false } }
    IconButton(onClick = { clipboard.setText(AnnotatedString(text)); copied = true }, modifier = modifier.size(32.dp)) {
        Icon(if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy, if (copied) "已复制" else "复制", Modifier.size(15.dp), tint = if (copied) palette.added else palette.muted)
    }
}

/** A block of code: what language it is, a button that copies it, and lines that scroll sideways instead of wrapping. */
@Composable
fun CodeBox(code: String, language: String? = null, modifier: Modifier = Modifier, title: String? = language, tint: Color = Color.Unspecified) {
    val colors = palette
    val text = remember(code, language, colors) { highlight(code.trimEnd('\n'), language, colors) }
    Surface(modifier.fillMaxWidth(), color = colors.card, shape = MaterialTheme.shapes.small, border = BorderStroke(1.dp, colors.line)) {
        Column {
            Row(Modifier.fillMaxWidth().height(32.dp).padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(title.orEmpty(), Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = colors.dim, maxLines = 1)
                CopyButton(code)
            }
            SelectionContainer {
                Text(
                    text, Modifier.horizontalScroll(rememberScrollState()).padding(start = 12.dp, end = 12.dp, bottom = 10.dp),
                    style = CodeStyle, color = if (tint == Color.Unspecified) colors.text else tint, softWrap = false,
                )
            }
        }
    }
}

/** What a change takes out and puts in, line by line. */
@Composable
fun DiffBox(lines: List<DiffLine>, modifier: Modifier = Modifier) {
    val colors = palette
    Surface(modifier.fillMaxWidth(), color = colors.card, shape = MaterialTheme.shapes.small, border = BorderStroke(1.dp, colors.line)) {
        SelectionContainer {
            Column(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 6.dp).width(androidx.compose.foundation.layout.IntrinsicSize.Max)) {
                for (line in lines) {
                    val color = when (line.sign) { '+' -> colors.added; '-' -> colors.removed; else -> Color.Unspecified }
                    Text(
                        line.sign + " " + line.text,
                        Modifier.fillMaxWidth().background(if (color == Color.Unspecified) Color.Transparent else color.copy(alpha = 0.13f)).padding(horizontal = 10.dp),
                        style = CodeStyle, color = if (color == Color.Unspecified) colors.muted else colors.text, softWrap = false,
                    )
                }
            }
        }
    }
}
