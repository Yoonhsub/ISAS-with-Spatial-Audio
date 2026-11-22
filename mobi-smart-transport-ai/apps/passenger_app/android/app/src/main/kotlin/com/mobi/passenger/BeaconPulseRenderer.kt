package com.mobi.passenger

import kotlin.math.PI
import kotlin.math.sin

/** Stereo PCM for the proximity beep. The audio thread only copies precomputed samples. */
internal class BeaconPulseRenderer(private val rate: Int) {
    private val pulse = ShortArray(rate * 120 / 1000) { i ->
        val ramp = rate / 100.0
        val envelope = minOf(1.0, i / ramp, (rate * 120 / 1000 - 1 - i) / ramp)
        (sin(2 * PI * 700 * i / rate) * envelope * 0.12 * Short.MAX_VALUE).toInt().toShort()
    }
    private var phase = 0

    fun reset() { phase = 0 }

    fun fill(stereo: ShortArray, intervalMs: Int) {
        val period = intervalMs * rate / 1000
        var i = 0
        while (i < stereo.size) {
            if (phase >= period) phase = 0
            val sample = if (phase < pulse.size) pulse[phase] else 0
            stereo[i++] = sample
            stereo[i++] = sample
            phase++
        }
    }
}
