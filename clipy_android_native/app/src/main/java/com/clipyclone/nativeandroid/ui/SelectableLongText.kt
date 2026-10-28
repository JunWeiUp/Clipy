package com.clipyclone.nativeandroid.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Typeface
import android.os.Build
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.widget.OverScroller
import android.widget.TextView
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.nestedscroll.*
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.roundToInt

@Stable
class TextDocumentState(initial: Int = 0) {
    private var saved by mutableIntStateOf(initial)
    internal var request by mutableIntStateOf(0)
        private set
    private var owner: Any? = null
    private var position: (() -> Int)? = null
    val offset: Int get() { val fallback = saved; return position?.invoke() ?: fallback }
    fun scrollTo(offset: Int) { saved = offset.coerceAtLeast(0); request++ }
    internal val requestedOffset: Int get() = saved
    internal fun changed(offset: Int) { saved = offset.coerceAtLeast(0) }
    internal fun bind(token: Any, read: () -> Int) { owner = token; position = read }
    internal fun unbind(token: Any) { if (owner === token) { saved = offset; owner = null; position = null } }
}

@Composable
fun rememberTextDocumentState(): TextDocumentState = rememberSaveable(saver = Saver(
    save = { it.offset }, restore = { TextDocumentState(it) })) { TextDocumentState() }

/**
 * Ordinary paragraphs keep the existing Compose selection UI. Large documents switch to a
 * bounded virtual document viewport: the complete String remains selectable/copyable without an
 * unbounded Compose Paragraph or packed Constraints height. No truncation or extra user step.
 */
@Composable
fun SelectableLongText(text: String, modifier: Modifier = Modifier, style: TextStyle = MaterialTheme.typography.bodyMedium,
                       state: TextDocumentState = rememberTextDocumentState(), onCopyFailed: () -> Unit = {},
                       copy: ((String) -> Boolean)? = null) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val active = LocalPageActive.current
    val chinese = LocalStrings.current.chinese
    val color = if (style.color == Color.Unspecified) LocalContentColor.current else style.color
    val highlight = MaterialTheme.colorScheme.primary.copy(alpha = .4f).toArgb()
    val sizeSp = if (style.fontSize == TextUnit.Unspecified) 14f else style.fontSize.value
    val sizePx = with(density) { sizeSp.sp.toPx() }.coerceAtLeast(1f)
    val linePx = when {
        style.lineHeight == TextUnit.Unspecified -> sizePx * 1.5f
        style.lineHeight.isEm -> sizePx * style.lineHeight.value
        else -> with(density) { style.lineHeight.toPx() }
    }
    val letterPx = when {
        style.letterSpacing == TextUnit.Unspecified -> 0f
        style.letterSpacing.isEm -> sizePx * style.letterSpacing.value
        else -> with(density) { style.letterSpacing.toPx() }
    }
    val currentFailure by rememberUpdatedState(onCopyFailed)
    val currentCopy by rememberUpdatedState(copy)
    BoxWithConstraints(modifier.fillMaxWidth().heightIn(max = LocalConfiguration.current.screenHeightDp.dp).padding(end = 3.dp)) {
        val width = constraints.maxWidth.coerceAtLeast(1)
        val safeHeight = when { width < 8191 -> 262142; width < 32767 -> 65534; width < 65535 -> 32766; else -> 8190 }
        val platform = remember(text, width, sizePx, linePx, letterPx) {
            val charsPerLine = (width / (sizePx * 2 + letterPx.coerceAtLeast(0f))).toInt().coerceAtLeast(1)
            val estimatedLines = ceil(text.length.toDouble() / charsPerLine) + text.count { it == '\n' } + 1
            text.length > 65536 || estimatedLines * maxOf(linePx, sizePx * 2) > safeHeight / 2
        }
        if (!platform) {
            val scroll = rememberScrollState(state.offset)
            DisposableEffect(scroll) { state.bind(scroll) { scroll.value }; onDispose { state.unbind(scroll) } }
            LaunchedEffect(state.request) { scroll.scrollTo(state.requestedOffset) }
            SelectionContainer(Modifier.fillMaxWidth().verticalScroll(scroll)) { Text(text, style = style) }
        } else {
            val dispatcher = remember { NestedScrollDispatcher() }
            val connection = remember { object : NestedScrollConnection {} }
            AndroidView(modifier = Modifier.fillMaxWidth().clipToBounds().nestedScroll(connection, dispatcher),
                factory = { SelectableDocumentView(it).apply { tag = "clipy-long-text" } },
                onReset = null,
                onRelease = { state.unbind(it); it.stopScrolling() },
                update = { view ->
                    view.copyText = { value -> currentCopy?.invoke(value) ?: safePlatformCopy(context, value) }
                    view.copyFailed = { currentFailure() }
                    view.preScroll = { delta -> dispatcher.dispatchPreScroll(Offset(0f, delta), NestedScrollSource.UserInput).y }
                    view.postScroll = { consumed, remaining -> dispatcher.dispatchPostScroll(Offset(0f, consumed), Offset(0f, remaining), NestedScrollSource.UserInput) }
                    view.changed = state::changed
                    view.isEnabled = active; view.isFocusable = active; view.isFocusableInTouchMode = active
                    view.importantForAccessibility = if (active) View.IMPORTANT_FOR_ACCESSIBILITY_AUTO else View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                    if (!active) { view.clearFocus(); view.stopScrolling(); view.suspendSelection() }
                    val family = when (style.fontFamily) { FontFamily.Monospace -> "monospace"; FontFamily.Serif -> "serif"; else -> "sans-serif" }
                    val weight = style.fontWeight?.weight ?: 400; val italic = style.fontStyle == FontStyle.Italic
                    val base = Typeface.create(family, Typeface.NORMAL)
                    val typeface = if (Build.VERSION.SDK_INT >= 28) Typeface.create(base, weight, italic)
                        else Typeface.create(base, when { weight >= 600 && italic -> Typeface.BOLD_ITALIC; weight >= 600 -> Typeface.BOLD; italic -> Typeface.ITALIC; else -> Typeface.NORMAL })
                    view.configure(text, sizePx, typeface, java.util.Locale.forLanguageTag(if (chinese) "zh-CN" else "en-US"),
                        color.toArgb(), highlight, letterPx, linePx)
                    if (view.restoreRequest != state.request) { view.restoreRequest = state.request; view.restoreOffset = state.requestedOffset; view.requestLayout() }
                    if (!view.bound) { view.restoreOffset = state.offset; view.bound = true }
                    state.bind(view) { view.restoreOffset ?: view.scrollY }
                })
        }
    }
}

fun safePlatformCopy(context: Context, text: String): Boolean = try {
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Clipy", text)); true
} catch (_: Exception) { false }

/** Whole-document indices with bounded paragraph layouts; never allocate one line table per document. */
internal class SelectableDocumentView(context: Context) : View(context) {
    var sourceText = ""
    val text: String get() = sourceText
    var copyText: (String) -> Boolean = { safePlatformCopy(context, it) }
    var copyFailed: () -> Unit = {}
    var changed: (Int) -> Unit = {}
    var preScroll: (Float) -> Float = { 0f }
    var postScroll: (Float, Float) -> Unit = { _, _ -> }
    var restoreOffset: Int? = null
    var restoreRequest = -1
    var bound = false
    var selectionStart = -1; private set
    var selectionEnd = -1; private set
    var documentHeight = 0; private set
    internal val cachedBlockCount: Int get() = layouts.size
    internal fun selectDocumentRange(start: Int, end: Int) {
        selectionStart = start.coerceIn(0, sourceText.length); selectionEnd = end.coerceIn(0, sourceText.length)
        startSelection(); invalidate()
    }
    fun suspendSelection() {
        val start = selectionStart; val end = selectionEnd
        actionMode?.finish(); selectionStart = start; selectionEnd = end
    }
    private val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG)
    private val selectionPaint = android.graphics.Paint()
    private var lineHeight = 1f
    private var fingerprint = ""
    private var indexedWidth = 0
    private var indexedText: String? = null
    private data class Block(val start: Int, val end: Int, val top: Int, val height: Int)
    private val blocks = ArrayList<Block>()
    private val layouts = object : LinkedHashMap<Int, android.text.StaticLayout>(4, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Int, android.text.StaticLayout>?) = size > 3
    }
    private var actionMode: ActionMode? = null
    private var copyLabel = "Copy"
    private var selectAllLabel = "Select all"
    private val fling = OverScroller(context)
    private val gesture = android.view.GestureDetector(context, object : android.view.GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true
        override fun onLongPress(e: MotionEvent) {
            longPressed = true
            val hit = offsetAt(e.x, e.y)
            val at = if (hit > 0 && (hit == sourceText.length || sourceText[hit].isWhitespace()) && !sourceText[hit - 1].isWhitespace()) hit - 1 else hit
            val words = java.text.BreakIterator.getWordInstance().apply { setText(sourceText) }
            selectionStart = if (at >= sourceText.length) sourceText.length.coerceAtLeast(1) - 1 else at
            selectionStart = words.preceding(selectionStart + 1).coerceAtLeast(0)
            selectionEnd = words.following(at.coerceAtMost(sourceText.length - 1)).let { if (it < 0) sourceText.length else it }
            startSelection(); invalidate()
        }
    })
    private var velocity: VelocityTracker? = null
    private var lastY = 0f
    private var startY = 0f
    private var dragging = false
    private var longPressed = false
    private var handle = 0
    private var handleX = 0f
    private var handleY = 0f
    private var autoScrolling = false
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val maxVelocity = ViewConfiguration.get(context).scaledMaximumFlingVelocity
    init { isVerticalScrollBarEnabled = true; isFocusableInTouchMode = true }
    fun configure(value: String, size: Float, typeface: Typeface, locale: java.util.Locale, color: Int, highlight: Int, spacing: Float, height: Float) {
        copyLabel = if (locale.language == "zh") "复制" else "Copy"
        selectAllLabel = if (locale.language == "zh") "全选" else "Select all"
        val key = "$size/${typeface.hashCode()}/$locale/$spacing/$height"
        paint.color = color; selectionPaint.color = highlight
        if (fingerprint != key || sourceText != value) {
            if (sourceText != value) { actionMode?.finish(); selectionStart = -1; selectionEnd = -1 }
            fingerprint = key; sourceText = value; paint.textSize = size; paint.typeface = typeface; paint.textLocale = locale
            paint.letterSpacing = spacing / size; lineHeight = height
            indexedText = null; layouts.clear(); requestLayout()
        }
        invalidate()
    }
    private fun makeLayout(start: Int, end: Int): android.text.StaticLayout {
        val extra = (lineHeight - (paint.fontMetrics.descent - paint.fontMetrics.ascent)).coerceAtLeast(0f)
        return android.text.StaticLayout.Builder.obtain(sourceText.substring(start, end), 0, end - start, paint, indexedWidth.coerceAtLeast(1))
            .setAlignment(android.text.Layout.Alignment.ALIGN_NORMAL).setTextDirection(android.text.TextDirectionHeuristics.LTR)
            .setIncludePad(false).setLineSpacing(extra, 1f).setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE).build()
    }
    private fun ensureIndex(width: Int) {
        if (indexedWidth == width && indexedText === sourceText) return
        indexedWidth = width.coerceAtLeast(1); indexedText = sourceText; blocks.clear(); layouts.clear()
        var start = 0; var top = 0
        while (start < sourceText.length) {
            var end = minOf(start + 4096, sourceText.length)
            if (end < sourceText.length) {
                var newline = end - 1
                while (newline >= start && sourceText[newline] != '\n') newline--
                if (newline >= start) end = newline + 1
                else {
                    // Cut only at an actual wrapped line boundary, preserving visible line geometry.
                    if (sourceText[end - 1].isHighSurrogate()) end--
                    val probe = makeLayout(start, end)
                    if (probe.lineCount > 1) end = start + probe.getLineStart(probe.lineCount - 1)
                }
            }
            if (end <= start) end = minOf(start + 1, sourceText.length)
            val layout = makeLayout(start, end)
            // A trailing newline creates an empty line in StaticLayout; the next block owns it.
            val height = if (end < sourceText.length && sourceText[end - 1] == '\n') layout.getLineTop(layout.lineCount - 1) else layout.height
            blocks.add(Block(start, end, top, height)); top += height
            start = end
        }
        documentHeight = top
    }
    private fun layout(index: Int) = layouts.getOrPut(index) { blocks[index].let { makeLayout(it.start, it.end) } }
    private fun blockAtY(y: Int): Int {
        var low = 0; var high = blocks.lastIndex
        while (low < high) { val mid = (low + high + 1) / 2; if (blocks[mid].top <= y) low = mid else high = mid - 1 }
        return low
    }
    private fun blockAtOffset(offset: Int): Int {
        var low = 0; var high = blocks.lastIndex
        while (low < high) { val mid = (low + high + 1) / 2; if (blocks[mid].start <= offset) low = mid else high = mid - 1 }
        return low
    }
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec).coerceAtLeast(1)
        ensureIndex(width)
        setMeasuredDimension(width, resolveSize(documentHeight, heightMeasureSpec))
    }
    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        ensureIndex(right - left)
        val target = restoreOffset ?: scrollY; restoreOffset = null
        scrollTo(0, target.coerceIn(0, maxScroll())); this.changed(scrollY)
    }
    override fun onDraw(canvas: android.graphics.Canvas) {
        if (blocks.isEmpty()) return
        var index = blockAtY(scrollY)
        val path = android.graphics.Path()
        val a = minOf(selectionStart, selectionEnd); val b = maxOf(selectionStart, selectionEnd)
        while (index < blocks.size && blocks[index].top < scrollY + height) {
            val block = blocks[index]; val layout = layout(index)
            canvas.save(); canvas.translate(0f, block.top.toFloat()); canvas.clipRect(0, 0, width, block.height)
            if (a >= 0 && b > block.start && a < block.end) {
                layout.getSelectionPath((a - block.start).coerceAtLeast(0), (b - block.start).coerceAtMost(block.end - block.start), path)
                canvas.drawPath(path, selectionPaint); path.reset()
            }
            layout.draw(canvas); canvas.restore(); index++
        }
        if (selectionStart >= 0 && actionMode != null) {
            val radius = 6 * resources.displayMetrics.density
            val highlight = selectionPaint.color
            selectionPaint.color = highlight or (0xff shl 24)
            for (offset in intArrayOf(selectionStart, selectionEnd)) {
                val point = pointAt(offset)
                if (point.second in scrollY.toFloat()..(scrollY + height).toFloat()) canvas.drawCircle(point.first, point.second, radius, selectionPaint)
            }
            selectionPaint.color = highlight
        }
    }
    private fun pointAt(offset: Int): Pair<Float, Float> {
        val index = blockAtOffset(offset); val block = blocks[index]; val layout = layout(index)
        val local = (offset - block.start).coerceIn(0, block.end - block.start)
        val line = layout.getLineForOffset(local)
        return layout.getPrimaryHorizontal(local) to (block.top + layout.getLineBottom(line)).toFloat()
    }
    private fun offsetAt(x: Float, y: Float): Int {
        if (blocks.isEmpty()) return 0
        val index = blockAtY((y + scrollY).toInt()); val block = blocks[index]; val layout = layout(index)
        val line = layout.getLineForVertical((y + scrollY - block.top).toInt())
        return block.start + layout.getOffsetForHorizontal(line, x)
    }
    private fun startSelection() {
        if (actionMode != null) { actionMode?.invalidate(); return }
        actionMode = startActionMode(object : ActionMode.Callback2() {
            override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
                menu.add(0, android.R.id.copy, 0, copyLabel).setShowAsAction(MenuItem.SHOW_AS_ACTION_IF_ROOM)
                menu.add(0, android.R.id.selectAll, 1, selectAllLabel).setShowAsAction(MenuItem.SHOW_AS_ACTION_IF_ROOM)
                return true
            }
            override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean { menu.findItem(android.R.id.copy)?.title = copyLabel; menu.findItem(android.R.id.selectAll)?.title = selectAllLabel; return true }
            override fun onActionItemClicked(mode: ActionMode, item: MenuItem) = onTextContextMenuItem(item.itemId)
            override fun onDestroyActionMode(mode: ActionMode) { actionMode = null; selectionStart = -1; selectionEnd = -1; invalidate() }
            override fun onGetContentRect(mode: ActionMode, view: View, outRect: android.graphics.Rect) {
                val point = pointAt(selectionStart.coerceAtLeast(0)); val y = (point.second - scrollY).toInt().coerceIn(0, height)
                outRect.set(0, (y - lineHeight).toInt().coerceAtLeast(0), width, y)
            }
        }, ActionMode.TYPE_FLOATING)
    }
    fun onTextContextMenuItem(id: Int): Boolean = when (id) {
        android.R.id.selectAll -> { selectionStart = 0; selectionEnd = sourceText.length; startSelection(); invalidate(); true }
        android.R.id.copy -> {
            val a = minOf(selectionStart, selectionEnd).coerceAtLeast(0); val b = maxOf(selectionStart, selectionEnd).coerceAtMost(sourceText.length)
            if (b > a && runCatching { copyText(sourceText.substring(a, b)) }.getOrDefault(false)) actionMode?.finish() else copyFailed()
            true
        }
        else -> false
    }
    private fun maxScroll() = (documentHeight - height).coerceAtLeast(0)
    override fun scrollTo(x: Int, y: Int) { super.scrollTo(0, y.coerceIn(0, maxScroll())) }
    override fun onScrollChanged(l: Int, t: Int, oldl: Int, oldt: Int) { super.onScrollChanged(l, t, oldl, oldt); changed(t); actionMode?.invalidateContentRect() }
    override fun computeVerticalScrollRange() = documentHeight
    override fun computeVerticalScrollExtent() = height
    override fun computeVerticalScrollOffset() = scrollY
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled || sourceText.isEmpty()) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                requestFocus()
                stopScrolling(); velocity = VelocityTracker.obtain().also { it.addMovement(event) }
                startY = event.rawY; lastY = startY; dragging = false; longPressed = false; handle = 0
                if (selectionStart >= 0 && actionMode != null) {
                    val radius = 28 * resources.displayMetrics.density
                    for ((i, offset) in intArrayOf(selectionStart, selectionEnd).withIndex()) {
                        val point = pointAt(offset)
                        if (abs(event.x - point.first) < radius && abs(event.y + scrollY - point.second) < radius) handle = i + 1
                    }
                }
            }
            MotionEvent.ACTION_MOVE -> {
                velocity?.addMovement(event)
                val delta = event.rawY - lastY; lastY = event.rawY
                if (handle != 0) {
                    parent?.requestDisallowInterceptTouchEvent(true)
                    handleX = event.x; handleY = event.y; updateHandle(); autoScrollSelection(); return true
                }
                if (!dragging && abs(event.rawY - startY) > slop) dragging = true
                if (dragging) {
                    parent?.requestDisallowInterceptTouchEvent(true)
                    val remaining = delta - preScroll(delta); val before = scrollY
                    scrollTo(0, (scrollY - remaining).roundToInt()); val own = (before - scrollY).toFloat()
                    postScroll(own, remaining - own)
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (dragging && event.actionMasked == MotionEvent.ACTION_UP) {
                    velocity?.addMovement(event); velocity?.computeCurrentVelocity(1000, maxVelocity.toFloat())
                    fling.fling(0, scrollY, 0, -(velocity?.yVelocity ?: 0f).roundToInt(), 0, 0, 0, maxScroll()); postInvalidateOnAnimation()
                }
                if (!dragging && handle == 0 && !longPressed && event.actionMasked == MotionEvent.ACTION_UP) {
                    actionMode?.finish(); performClick()
                }
                velocity?.recycle(); velocity = null; dragging = false; handle = 0
            }
        }
        if (handle == 0) gesture.onTouchEvent(event)
        return true
    }
    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if (event.isCtrlPressed && keyCode == android.view.KeyEvent.KEYCODE_A) return onTextContextMenuItem(android.R.id.selectAll)
        if (event.isCtrlPressed && keyCode == android.view.KeyEvent.KEYCODE_C) return onTextContextMenuItem(android.R.id.copy)
        return super.onKeyDown(keyCode, event)
    }
    override fun performClick(): Boolean { super.performClick(); return true }
    private fun updateHandle() {
        val offset = offsetAt(handleX, handleY)
        if (handle == 1) selectionStart = offset else selectionEnd = offset
        actionMode?.invalidateContentRect(); invalidate()
    }
    private fun autoScrollSelection() {
        if (autoScrolling) return
        val edge = 32 * resources.displayMetrics.density
        val delta = when { handleY < edge -> -edge / 3; handleY > height - edge -> edge / 3; else -> 0f }
        if (delta == 0f || handle == 0) return
        val before = scrollY; scrollTo(0, scrollY + delta.toInt()); updateHandle()
        if (before != scrollY) { autoScrolling = true; postOnAnimation { autoScrolling = false; if (handle != 0) autoScrollSelection() } }
    }
    override fun computeScroll() { if (fling.computeScrollOffset()) { scrollTo(0, fling.currY); postInvalidateOnAnimation() } }
    fun stopScrolling() { if (!fling.isFinished) fling.abortAnimation(); handle = 0 }
    override fun onDetachedFromWindow() { stopScrolling(); velocity?.recycle(); velocity = null; actionMode?.finish(); layouts.clear(); super.onDetachedFromWindow() }
    override fun onInitializeAccessibilityNodeInfo(info: android.view.accessibility.AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = TextView::class.java.name
        if (blocks.isNotEmpty()) { val first = blockAtY(scrollY); val last = blockAtY(scrollY + height); info.text = sourceText.substring(blocks[first].start, blocks[last].end) }
        info.isScrollable = maxScroll() > 0
        info.addAction(android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD)
        info.addAction(android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD)
        info.addAction(android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction.ACTION_COPY)
        info.addAction(android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_SELECTION)
    }
    override fun performAccessibilityAction(action: Int, arguments: android.os.Bundle?): Boolean = when (action) {
        android.view.accessibility.AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> { scrollTo(0, scrollY + height); true }
        android.view.accessibility.AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> { scrollTo(0, scrollY - height); true }
        android.view.accessibility.AccessibilityNodeInfo.ACTION_COPY -> { if (selectionStart < 0) onTextContextMenuItem(android.R.id.selectAll); onTextContextMenuItem(android.R.id.copy) }
        android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION -> {
            if (blocks.isEmpty()) false else {
                val base = blocks[blockAtY(scrollY)].start
                selectDocumentRange(base + (arguments?.getInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT) ?: 0),
                    base + (arguments?.getInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT) ?: 0)); true
            }
        }
        else -> super.performAccessibilityAction(action, arguments)
    }
}
