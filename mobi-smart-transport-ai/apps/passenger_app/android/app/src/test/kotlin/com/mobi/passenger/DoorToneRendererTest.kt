package com.mobi.passenger

import org.junit.Assert.assertTrue
import org.junit.Test

class DoorToneRendererTest {
    @Test fun centeredBeepIsAudibleAndBalancedBetweenEars() {
        val renderer = DoorToneRenderer(48000).apply { setAngle(0.0) }
        val pcm = ShortArray(48000 * 2)
        for (i in 0 until 48000) renderer.render(i, pcm, i * 2)
        val left = (0 until 48000).sumOf { pcm[it * 2].toLong() * pcm[it * 2] }
        val right = (0 until 48000).sumOf { pcm[it * 2 + 1].toLong() * pcm[it * 2 + 1] }
        assertTrue(left > 0 && right > 0)
        assertTrue(kotlin.math.abs(left - right) < left / 100)
    }

    @Test fun leftAndRightReverseEarEnergy() {
        fun energies(angle: Double): Pair<Long, Long> {
            val renderer = DoorToneRenderer(48000).apply { setAngle(angle) }
            val pcm = ShortArray(48000 * 2)
            for (i in 0 until 48000) renderer.render(i, pcm, i * 2)
            val left = (0 until 48000).sumOf { pcm[it * 2].toLong() * pcm[it * 2] }
            val right = (0 until 48000).sumOf { pcm[it * 2 + 1].toLong() * pcm[it * 2 + 1] }
            return left to right
        }
        val left = energies(-60.0)
        val right = energies(60.0)
        assertTrue(left.first > left.second)
        assertTrue(right.second > right.first)
        assertTrue(kotlin.math.abs(left.first - right.second) < left.first / 20)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsNonFiniteDirection() {
        DoorToneRenderer(48000).setAngle(Double.NaN)
    }
}
