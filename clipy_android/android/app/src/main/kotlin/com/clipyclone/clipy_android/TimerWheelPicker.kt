package com.clipyclone.clipy_android

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.util.AttributeSet
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.animation.DecelerateInterpolator
import androidx.core.graphics.ColorUtils
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * MIUI system-clock style h:mm:ss wheel picker: three vertical scroll
 * columns (hours 0..23, minutes/seconds 0..59), five visible rows whose
 * size and color interpolate continuously with distance from the selected
 * row, and colons between columns. Smoothness notes: every drag/settle
 * frame invalidates (no row-stepping), each column owns its settle animator
 * so touching another column never interrupts it mid-flight, and released
 * wheels always settle exactly onto an integer row so the three selected
 * digits stay aligned. Tap a row to jump; fling carries momentum.
 */
class TimerWheelPicker @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    var onDurationChanged: ((hours: Int, minutes: Int, seconds: Int) -> Unit)? = null

    private val maxes = intArrayOf(24, 60, 60)
    private val values = intArrayOf(0, 0, 0)
    private val pos = floatArrayOf(0f, 0f, 0f)
    private val animators = arrayOfNulls<ValueAnimator>(3)

    private val density = resources.displayMetrics.density
    private fun dp(v: Int): Float = v * density
    private fun sp(v: Float): Float = v * density

    private val rowHeight = dp(54)
    private val sideRows = 2

    private val selectedSize = sp(42f)
    private val farSize = sp(22f)
    private val selectedColor = 0xFFF2F2F2.toInt()
    private val farColor = 0xFF343434.toInt()

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.MONOSPACE
    }

    private var activeColumn = -1
    private var downY = 0f
    private var startPos = 0f
    private var lastMoveY = 0f
    private var lastMoveTime = 0L
    private var velocity = 0f // rows/sec, low-passed
    private var moved = false

    fun setDuration(hours: Int, minutes: Int, seconds: Int) {
        val target = intArrayOf(
            hours.coerceIn(0, 23),
            minutes.coerceIn(0, 59),
            seconds.coerceIn(0, 59),
        )
        for (i in 0..2) {
            values[i] = target[i]
            // Spin the shortest wrapped path from wherever the wheel is.
            val delta = shortestDelta(pos[i], target[i].toFloat(), maxes[i])
            animateTo(i, pos[i] + delta, fast = true)
        }
    }

    fun durationSeconds(): Int = values[0] * 3600 + values[1] * 60 + values[2]

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        setMeasuredDimension(w, (rowHeight * (sideRows * 2 + 1)).toInt())
    }

    private fun columnCenterX(i: Int): Float = width * (i * 2 + 1) / 6f

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val cy = height / 2f
        for (i in 0..2) {
            val cx = columnCenterX(i)
            val b = pos[i]
            // One extra row beyond the fade so entries slide in smoothly.
            val firstRow = Math.floor(b.toDouble()).toInt() - sideRows - 1
            val lastRow = Math.ceil(b.toDouble()).toInt() + sideRows + 1
            for (j in firstRow..lastRow) {
                val distance = j - b
                if (abs(distance) > sideRows + 0.9f) continue
                styleFor(abs(distance))
                val y = cy + distance * rowHeight
                canvas.drawText(
                    String.format(Locale.ROOT, "%02d", floorMod(j, maxes[i])),
                    cx,
                    y + paint.textSize / 3,
                    paint,
                )
            }
        }
        // Colons between columns, on the selected (center) row only — like
        // the system clock, the surrounding rows are bare numbers.
        styleFor(0f)
        val colonY = cy + paint.textSize / 3
        for (gap in 0..1) {
            val x = (columnCenterX(gap) + columnCenterX(gap + 1)) / 2f
            canvas.drawText(":", x, colonY, paint)
        }
    }

    /** Continuous size/color ramp by distance from the selected row. */
    private fun styleFor(distance: Float) {
        val t = (distance / sideRows).coerceIn(0f, 1f)
        paint.textSize = selectedSize + (farSize - selectedSize) * t
        paint.color = ColorUtils.blendARGB(selectedColor, farColor, t)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                activeColumn = (event.x / width * 3f).toInt().coerceIn(0, 2)
                downY = event.y
                startPos = pos[activeColumn]
                lastMoveY = event.y
                lastMoveTime = event.eventTime
                velocity = 0f
                moved = false
                // Only the touched column's settle animation stops; other
                // columns keep settling so their digits stay aligned.
                animators[activeColumn]?.cancel()
                animators[activeColumn] = null
                parent?.requestDisallowInterceptTouchEvent(true)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dy = event.y - downY
                if (abs(dy) > dp(4)) moved = true
                pos[activeColumn] = startPos - dy / rowHeight
                val dt = (event.eventTime - lastMoveTime).coerceAtLeast(1L)
                val instant = -(event.y - lastMoveY) / rowHeight / (dt / 1000f)
                velocity = if (velocity == 0f) instant else velocity * 0.6f + instant * 0.4f
                lastMoveY = event.y
                lastMoveTime = event.eventTime
                tick(activeColumn)
                invalidate()
                return true
            }
            MotionEvent.ACTION_UP -> {
                if (!moved) {
                    val tapped = (pos[activeColumn] +
                        (event.y - height / 2f) / rowHeight).roundToInt()
                    animateTo(activeColumn, tapped.toFloat())
                } else {
                    val flingRows = (velocity * 0.3f).coerceIn(-8f, 8f)
                    animateTo(activeColumn, (pos[activeColumn] + flingRows).roundToInt().toFloat())
                }
                performClick()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean = super.performClick()

    /** Haptic + value callback whenever the resting value changes. */
    private fun tick(column: Int) {
        val selected = floorMod(pos[column].roundToInt(), maxes[column])
        if (selected != values[column]) {
            values[column] = selected
            performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            onDurationChanged?.invoke(values[0], values[1], values[2])
        }
    }

    private fun animateTo(column: Int, target: Float, fast: Boolean = false) {
        animators[column]?.cancel()
        val rows = abs(target - pos[column])
        val duration = if (fast) {
            (140f + rows * 30f).coerceAtMost(420f)
        } else {
            (180f + rows * 45f).coerceAtMost(520f)
        }.toLong()
        animators[column] = ValueAnimator.ofFloat(pos[column], target).apply {
            this.duration = duration
            interpolator = DecelerateInterpolator(1.4f)
            addUpdateListener {
                pos[column] = it.animatedValue as Float
                tick(column)
                invalidate()
            }
            addListener(object : android.animation.Animator.AnimatorListener {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    pos[column] = target
                    tick(column)
                    invalidate()
                }
                override fun onAnimationCancel(animation: android.animation.Animator) {}
                override fun onAnimationStart(animation: android.animation.Animator) {}
                override fun onAnimationRepeat(animation: android.animation.Animator) {}
            })
            start()
        }
    }

    private fun shortestDelta(from: Float, to: Float, mod: Int): Float {
        var wrapped = ((to - from) % mod + mod) % mod
        if (wrapped > mod / 2f) wrapped -= mod
        return wrapped
    }

    private fun floorMod(v: Int, m: Int): Int = ((v % m) + m) % m
}
