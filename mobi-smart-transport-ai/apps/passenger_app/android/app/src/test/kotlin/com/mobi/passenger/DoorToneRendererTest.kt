package com.mobi.passenger

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.abs

class DoorToneRendererTest {
    private fun pulse(angle: Double): ShortArray {
        val renderer = DoorToneRenderer(48000)
        renderer.setAngle(angle)
        return ShortArray(6000 * 2).also { pcm ->
            for (i in 0 until pcm.size / 2) renderer.render(i, pcm, i * 2)
        }
    }

    @Test fun centerIsBalancedAndDoorMovesToTheCorrectEar() {
        val center = pulse(0.0)
        val right = pulse(20.0)
        val left = pulse(-20.0)
        var nearEnergy = 0.0
        var farEnergy = 0.0
        for (i in right.indices step 2) {
            assertEquals(center[i], center[i + 1])
            assertEquals(right[i], left[i + 1])
            assertEquals(right[i + 1], left[i])
            assertTrue(abs(right[i + 1].toInt()) <= 3933)
            nearEnergy += right[i + 1].toDouble() * right[i + 1]
            farEnergy += right[i].toDouble() * right[i]
        }
        assertTrue(nearEnergy > 4 * farEnergy)
        assertTrue((right.indices step 2).first { right[it + 1].toInt() != 0 } <
            (right.indices step 2).first { right[it].toInt() != 0 })
        assertTrue(right.takeLast(100).all { it.toInt() == 0 })
    }

    @Test fun aSmallRightTurnIsClearlyRightWeighted() {
        val right = pulse(10.0)
        var nearEnergy = 0.0
        var farEnergy = 0.0
        for (i in right.indices step 2) {
            nearEnergy += right[i + 1].toDouble() * right[i + 1]
            farEnergy += right[i].toDouble() * right[i]
        }
        // More than 14 dB at only 10°: a deliberate, unmistakable demo cue.
        assertTrue(nearEnergy > 25 * farEnergy)
    }
}
