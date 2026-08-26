package com.clipyclone.clipy_android

import android.content.Context
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.SweepGradient
import android.util.AttributeSet
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Radial 0..40-minute dial for the timer panel, in the spirit of the MIUI
 * clock timer picker: a thick ring that fills as you drag a glowing knob
 * clockwise from 12 o'clock — minute ticks along the ring, a label every 5
 * minutes, the selected label highlighted, and the big readout rendered by
 * the centered overlay TextView. The dial is the panel's single focal
 * element; everything else stays quiet.
 */
class TimerDialView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    var onMinutesChanged: ((Int) -> Unit)? = null

    var minutes: Int = TimerWidgetProvider.DEFAULT_MINUTES
        private set

    private val maxMinutes = TimerWidgetProvider.MAX_MINUTES
    private val degPerMinute = 360f / maxMinutes

    private val density = resources.displayMetrics.density
    private fun dp(v: Int): Float = v * density
    private fun sp(v: Int): Float = v * density

    private var centerX = 0f
    private var centerY = 0f
    private var ringRadius = 0f
    private var labelRadius = 0f

    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(10)
        color = 0x1EFFFFFF
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(10)
        strokeCap = Paint.Cap.ROUND
    }
    private val minorTickPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * density
        color = 0x30FFFFFF
    }
    private val majorTickPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2f * density
        color = 0x59FFFFFF
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF8DA0BC.toInt()
        textSize = sp(13)
        textAlign = Paint.Align.CENTER
    }
    private val labelActivePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = TimerWidgetProvider.COLOR_ACCENT_LIGHT
        textSize = sp(14)
        typeface = android.graphics.Typeface.DEFAULT_BOLD
        textAlign = Paint.Align.CENTER
    }
    private val thumbGlowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val thumbPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = TimerWidgetProvider.COLOR_ACCENT
    }
    private val thumbDotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF0B1220.toInt()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        // Force a square dial from the available width.
        val w = MeasureSpec.getSize(widthMeasureSpec)
        setMeasuredDimension(w, w)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        centerX = w / 2f
        centerY = h / 2f
        ringRadius = w / 2f - dp(34)
        labelRadius = ringRadius + dp(18)
        fillPaint.shader = SweepGradient(
            centerX, centerY,
            TimerWidgetProvider.COLOR_ACCENT, TimerWidgetProvider.COLOR_ACCENT_LIGHT,
        ).apply {
            val rotate = Matrix()
            rotate.setRotate(-90f, centerX, centerY)
            setLocalMatrix(rotate)
        }
        thumbGlowPaint.shader = RadialGradient(
            0f, 0f, dp(30),
            0x664F9CF9.toInt(), 0x004F9CF9.toInt(),
            Shader.TileMode.CLAMP,
        )
    }

    fun setValue(value: Int) {
        minutes = value.coerceIn(0, maxMinutes)
        invalidate()
    }

    private fun angleFor(value: Int): Float = value * degPerMinute - 90f

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        // Ring track + accent sweep from 12 o'clock to the knob.
        canvas.drawCircle(centerX, centerY, ringRadius, trackPaint)
        if (minutes > 0) {
            val rect = android.graphics.RectF(
                centerX - ringRadius, centerY - ringRadius,
                centerX + ringRadius, centerY + ringRadius,
            )
            canvas.drawArc(rect, -90f, minutes * degPerMinute, false, fillPaint)
        }

        // Minute ticks laid on the ring; every 5th is longer and brighter.
        for (m in 1..maxMinutes) {
            val major = m % 5 == 0
            val len = if (major) dp(12) else dp(7)
            val rad = Math.toRadians(angleFor(m).toDouble())
            val c = cos(rad).toFloat()
            val s = sin(rad).toFloat()
            canvas.drawLine(
                centerX + c * (ringRadius - len / 2),
                centerY + s * (ringRadius - len / 2),
                centerX + c * (ringRadius + len / 2),
                centerY + s * (ringRadius + len / 2),
                if (major) majorTickPaint else minorTickPaint,
            )
        }

        // Labels every 5 minutes; the one nearest the knob is highlighted.
        val nearest5 = (minutes / 5f).roundToInt() * 5
        for (m in 0..maxMinutes step 5) {
            val rad = Math.toRadians(angleFor(m).toDouble())
            val x = centerX + cos(rad).toFloat() * labelRadius
            val y = centerY + sin(rad).toFloat() * labelRadius
            val paint = if (m == nearest5) labelActivePaint else labelPaint
            canvas.drawText(m.toString(), x, y + paint.textSize / 3, paint)
        }

        // Knob on the ring: soft glow, solid accent, dark center dot.
        val rad = Math.toRadians(angleFor(minutes).toDouble())
        val save = canvas.save()
        canvas.translate(
            centerX + cos(rad).toFloat() * ringRadius,
            centerY + sin(rad).toFloat() * ringRadius,
        )
        canvas.drawCircle(0f, 0f, dp(30), thumbGlowPaint)
        canvas.drawCircle(0f, 0f, dp(14), thumbPaint)
        canvas.drawCircle(0f, 0f, dp(4), thumbDotPaint)
        canvas.restoreToCount(save)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                applyPosition(event.x, event.y)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                applyPosition(event.x, event.y)
                return true
            }
            MotionEvent.ACTION_UP -> {
                performClick()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean = super.performClick()

    /** Absolute-angle mapping: wherever you touch on the dial is the value. */
    private fun applyPosition(x: Float, y: Float) {
        val angle = Math.toDegrees(
            atan2(y - centerY, x - centerX).toDouble(),
        ).toFloat()
        val fromTop = (angle + 90f + 360f) % 360f
        val value = (fromTop / degPerMinute).roundToInt().coerceIn(0, maxMinutes)
        if (value != minutes) {
            minutes = value
            performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            onMinutesChanged?.invoke(minutes)
            invalidate()
        }
    }
}
