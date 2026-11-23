package com.mobi.passenger

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tanh

/** Short 700 Hz door cue with ear-specific timing and high-frequency head shadow. */
internal class DoorToneRenderer(private val rate: Int) {
    private val frames = rate * 120 / 1000
    private val low = DoubleArray(frames + 1)
    private val high = DoubleArray(frames + 1)
    private var leftDelay = 0.0
    private var rightDelay = 0.0
    private var leftGain = 0.0
    private var rightGain = 0.0
    private var leftTreble = 1.0
    private var rightTreble = 1.0

    init {
        for (i in 0 until frames) {
            val envelope = minOf(1.0, i / (rate * .006), (frames - 1 - i) / (rate * .010))
            val phase = 2 * PI * 700 * i / rate
            val amplitude = envelope * .12 * Short.MAX_VALUE
            low[i] = amplitude * .70 * sin(phase)
            high[i] = amplitude * (.19 * sin(3 * phase) + .11 * sin(5 * phase))
        }
        setAngle(0.0)
    }

    fun setAngle(degrees: Double) {
        val radians = Math.toRadians(degrees)
        val side = sin(radians)
        val delay = side * .00066 * rate
        leftDelay = maxOf(0.0, delay)
        rightDelay = maxOf(0.0, -delay)
        // This cue is a directional instruction, not ambient stereo.  In the demo,
        // a door only 10° off centre must already be unmistakable: strongly attenuate
        // the far ear, then approach a hard pan as the target moves farther sideways.
        val pan = .999 * tanh(10.0 * side) / tanh(10.0)
        leftGain = sqrt((1 - pan) / 2)
        rightGain = sqrt((1 + pan) / 2)
        val rearTreble = 1 - .40 * maxOf(0.0, -cos(radians))
        leftTreble = rearTreble * (1 - .85 * maxOf(0.0, side))
        rightTreble = rearTreble * (1 - .85 * maxOf(0.0, -side))
    }

    private fun sample(position: Double, gain: Double, treble: Double): Short {
        if (position < 0 || position >= frames) return 0
        val i = position.toInt()
        val t = position - i
        val bass = low[i] + t * (low[i + 1] - low[i])
        val harmonics = high[i] + t * (high[i + 1] - high[i])
        return ((bass + treble * harmonics) * gain).toInt().toShort()
    }

    fun render(frame: Int, pcm: ShortArray, offset: Int) {
        pcm[offset] = sample(frame - leftDelay, leftGain, leftTreble)
        pcm[offset + 1] = sample(frame - rightDelay, rightGain, rightTreble)
    }
}
