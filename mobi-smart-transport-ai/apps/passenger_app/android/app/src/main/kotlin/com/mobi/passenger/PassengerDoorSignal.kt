package com.mobi.passenger

import kotlin.math.exp
import kotlin.math.abs
import kotlin.math.roundToInt

/** All timestamps share Android's monotonic elapsed-realtime clock. */
internal class PassengerDoorSignal(private val photoDemo: Boolean = false, private val visualOnly: Boolean = false) {
    data class Cue(val interval: Int, val angle: Double?, val beaconAge: Int, val headingAge: Int)
    private data class Heading(val at: Long, val degrees: Double)
    private val headings = ArrayDeque<Heading>()
    private var beaconAt: Long? = null
    private var strength = 0.0
    private var previousRssi: Int? = null
    private var approachBaseline: Int? = null
    private var retreatSince: Long? = null
    private var approachPlayed = false
    private var approachUntil = 0L
    private var visualGuidance = false

    fun beginVisualGuidance() {
        visualGuidance = true
        approachUntil = 0L
    }
    private var frameAt: Long? = null
    private var lastFrame: Long? = null
    private var imageAngle = 0.0
    private var worldAngle: Double? = null

    fun beacon(rssi: Int, at: Long, now: Long) {
        if (rssi !in -120..-1 || now - at !in 0..2999 || at <= (beaconAt ?: -1L)) return
        val previous = beaconAt
        if (previous == null || at - previous >= 3000) {
            if (!photoDemo) clearDoor()
            previousRssi = null
            // Losing advertisements stops stale output, but does not prove the bus moved away.
            if (!approachPlayed) approachBaseline = null
            retreatSince = null
            approachUntil = 0L
            strength = rssi.toDouble()
        } else {
            // Sparse advertising must not turn a short filter into seconds of lag.
            val weight = 1.0 - exp(-(at - previous) / 180.0)
            strength += (rssi - strength) * weight
        }
        val last = previousRssi
        if (!visualGuidance && approachPlayed) {
            val baseline = checkNotNull(approachBaseline)
            if (strength < baseline + 3) approachUntil = 0L
            if (rssi <= baseline + 2 && strength <= baseline + 2) {
                val since = retreatSince ?: at
                retreatSince = since
                if (at - since >= 3000) {
                    approachPlayed = false
                    approachBaseline = if (last == null) null else maxOf(last, rssi)
                    retreatSince = null
                }
            } else {
                retreatSince = null
            }
        } else if (!visualGuidance && last != null) {
            // Two samples establish the weaker reference; an isolated dip or spike cannot trigger it.
            val baseline = minOf(approachBaseline ?: Int.MAX_VALUE, maxOf(last, rssi))
            approachBaseline = baseline
            // On the S21 the stationary far beacon fluctuated between -80 and -70 dBm.
            val approachThreshold = maxOf(baseline + 6, -67)
            if (minOf(last, rssi) >= approachThreshold && strength >= approachThreshold) {
                approachPlayed = true
                approachUntil = at + 1200
            }
        }
        previousRssi = rssi
        beaconAt = at
    }

    fun heading(degrees: Double?, at: Long, now: Long) {
        if (degrees == null || !degrees.isFinite()) {
            headings.clear()
            worldAngle = null
            return
        }
        if (now - at !in 0..249 || at <= (headings.lastOrNull()?.at ?: -1L)) return
        headings.addLast(Heading(at, degrees))
        while (headings.isNotEmpty() && now - headings.first().at > 1200) headings.removeFirst()
    }

    fun door(degrees: Double?, at: Long, now: Long) {
        if (at <= (lastFrame ?: -1L) || now - at !in 0..999) return
        lastFrame = at
        if (degrees == null) {
            // A fresh heading can still track the last door for at most four seconds.
            if (worldAngle == null) frameAt = null
            return
        }
        val freshBeacon = beaconAt?.let { now - it in 0..2999 } == true
        if (!degrees.isFinite() || abs(degrees) >= 90 || (!photoDemo && !visualOnly && !freshBeacon)) return
        beginVisualGuidance()
        imageAngle = degrees
        frameAt = at
        val match = headings.minByOrNull { abs(it.at - at) }
        worldAngle = if (match != null && abs(match.at - at) <= 150) match.degrees + degrees else null
    }

    fun clearDoor() {
        frameAt = null
        lastFrame = null
        worldAngle = null
    }

    fun cue(now: Long): Cue? {
        val age = beaconAt?.let { now - it }?.takeIf { it in 0..2999 }
        if (!photoDemo && !visualOnly && age == null) return null
        val frameAge = frameAt?.let { now - it }
        val sample = headings.lastOrNull()
        val sensorAge = sample?.let { now - it.at }
        val target = worldAngle
        val angle = when {
            target != null && frameAge != null && frameAge in 0..3999 &&
                sample != null && sensorAge != null && sensorAge in 0..249 ->
                ((target - sample.degrees + 540) % 360) - 180
            frameAge != null && frameAge in 0..999 -> imageAngle
            else -> null
        }
        if (angle == null && (age == null || visualGuidance || now >= approachUntil)) return null
        // Once the door is guiding, proximity no longer changes its rhythm.
        val interval = if (angle != null) 800 else
            (1400 - ((strength.roundToInt() + 85) / 40.0).coerceIn(0.0, 1.0) * 1180).roundToInt()
        return Cue(interval, angle, age?.toInt() ?: -1, sensorAge?.takeIf { it in 0..249 }?.toInt() ?: -1)
    }
}
