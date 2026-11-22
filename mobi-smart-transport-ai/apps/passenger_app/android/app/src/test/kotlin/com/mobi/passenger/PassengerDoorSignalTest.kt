package com.mobi.passenger

import org.junit.Assert.*
import org.junit.Test

class PassengerDoorSignalTest {
    @Test fun photoUsesFreshCameraAndPhoneHeadingWithoutPretendingToReceiveBle() {
        val s = PassengerDoorSignal(photoDemo = true)
        assertNull(s.cue(1000))
        s.heading(15.0, 1000, 1000)
        s.door(-20.0, 1000, 1010)
        assertEquals(-20.0, s.cue(1010)!!.angle!!, 0.01)
        assertEquals(-1, s.cue(1010)!!.beaconAge)
        s.heading(-30.0, 1550, 1550)
        assertEquals(25.0, s.cue(1550)!!.angle!!, 0.01)
        assertNull(s.cue(5000))
        s.clearDoor()
        assertNull(s.cue(5001))
        val regular = PassengerDoorSignal()
        regular.door(-20.0, 1000, 1010)
        assertNull(regular.cue(1010))
    }

    @Test fun steadyNoiseRetreatAndIsolatedSpikesStayQuiet() {
        val s = PassengerDoorSignal()
        listOf(-50, -50, -72, -49, -35, -50, -51, -53, -58, -65).forEachIndexed { i, rssi ->
            val at = 1000L + i * 250
            s.beacon(rssi, at, at)
            assertNull(s.cue(at))
        }
    }

    @Test fun oneApproachSurvivesTheRecordedS21ReceptionGap() {
        val signal = PassengerDoorSignal()
        val samples = listOf(
            326023L to -67, 326317L to -65, 326618L to -61, 327541L to -63,
            327849L to -67, 328455L to -62, 328758L to -62, 329071L to -58,
            329367L to -57, 329657L to -56, 333318L to -50, 333927L to -45,
            334239L to -40, 334531L to -35, 334837L to -40, 335145L to -40,
            335449L to -34, 335739L to -36, 336049L to -33, 336357L to -40,
            338198L to -34, 338502L to -32
        )
        var bursts = 0
        var nextSample = 0
        var audible = false
        for (t in samples.first().first..samples.last().first + 1500) {
            if (nextSample < samples.size && t == samples[nextSample].first) {
                signal.beacon(samples[nextSample++].second, t, t)
            }
            val cue = signal.cue(t)
            if (!audible && cue != null) bursts++
            audible = cue != null
        }
        assertEquals(1, bursts)
        assertFalse(audible)
    }

    @Test fun confirmedApproachBeepsOnceAndUsesFreshAdvertisementTime() {
        val s = PassengerDoorSignal()
        s.beacon(-80, 1000, 1000)
        s.beacon(-81, 1250, 1250)
        s.beacon(-67, 1500, 1500)
        assertNull(s.cue(1500))
        s.beacon(-65, 1750, 1750)
        val approach = s.cue(1750)!!
        assertTrue(approach.interval in 221..1399)
        assertNull(approach.angle)
        s.beacon(-30, 2050, 2050)
        s.beacon(-90, 1100, 2060)
        assertEquals(220, s.cue(2060)!!.interval)
        s.beacon(-30, 2950, 2950)
        assertNull(s.cue(2950))
        s.beacon(-28, 3500, 3500)
        assertNull(s.cue(3500))
        assertNull(s.cue(6500))
        // Fresh weak readings confirm departure before a second approach.
        for (at in 6600L..9600L step 500) {
            s.beacon(-80, at, at)
            assertNull(s.cue(at))
        }
        s.beacon(-39, 9900, 9900)
        s.beacon(-39, 10200, 10200)
        assertEquals(220, s.cue(10200)!!.interval)
    }

    @Test fun farS21FluctuationsLeaveTheFirstApproachAvailable() {
        val s = PassengerDoorSignal()
        val far = listOf(2469L to -79, 2774L to -79, 3080L to -80, 3387L to -79,
            4607L to -70, 6742L to -72, 7663L to -77)
        for ((at, rssi) in far) {
            s.beacon(rssi, at, at)
            assertNull(s.cue(at))
        }
        s.beacon(-57, 8000, 8000)
        s.beacon(-54, 8300, 8300)
        assertNotNull(s.cue(8300))
    }

    @Test fun missingAdvertisementsDoNotCountAsTimeSpentFarAway() {
        val s = PassengerDoorSignal()
        listOf(-70, -70, -52, -50).forEachIndexed { i, rssi ->
            val at = 1000L + i * 300
            s.beacon(rssi, at, at)
        }
        assertNotNull(s.cue(1900))
        val samples = listOf(4000L to -74, 4400L to -74, 8800L to -74, 9200L to -74,
            9600L to -48, 10000L to -42, 80000L to -38, 80300L to -30, 80600L to -28)
        for ((at, rssi) in samples) {
            s.beacon(rssi, at, at)
            assertNull(s.cue(at))
        }
    }

    @Test fun arrivalPermanentlySilencesApproachForThisGuideEvenIfDoorLeavesView() {
        val s = PassengerDoorSignal(photoDemo = true)
        listOf(-80, -80, -40, -40).forEachIndexed { i, v ->
            val t = 1000L + i * 250
            s.beacon(v, t, t)
        }
        assertNotNull(s.cue(1750))
        s.beginVisualGuidance()
        assertNull(s.cue(1751))
        s.heading(10.0, 1800, 1800)
        s.door(20.0, 1800, 1800)
        s.door(null, 1900, 1900)
        s.heading(55.0, 2100, 2100)
        assertEquals(-25.0, s.cue(2100)!!.angle!!, 0.01)
        assertEquals(800, s.cue(2100)!!.interval)
        s.clearDoor()
        listOf(-80, -80, -40, -40).forEachIndexed { i, v ->
            val t = 6000L + i * 250
            s.beacon(v, t, t)
            assertNull(s.cue(t))
        }
    }

    @Test fun stereoBeepKeepsItsPeriodAndHeadroomBeyondFiveMinutes() {
        val renderer = BeaconPulseRenderer(48000)
        val pcm = ShortArray(960)
        var last = -1
        var frame = 0
        var pulses = 0
        var silent = 1000
        repeat(31000) {
            renderer.fill(pcm, 220)
            for (i in pcm.indices step 2) {
                val v = pcm[i].toInt()
                if (v != pcm[i + 1].toInt() || kotlin.math.abs(v) > 3933) fail("Bad stereo PCM at frame $frame")
                if (v == 0) silent++ else {
                    if (silent > 100) {
                        if (last >= 0) assertEquals(10560, frame - last)
                        pulses++
                        last = frame
                    }
                    silent = 0
                }
                frame++
            }
        }
        assertEquals(1410, pulses)
    }

    @Test fun cameraAndPhoneYawKeepDoorBearingAcrossTurns() {
        val s = PassengerDoorSignal()
        s.heading(10.0, 1000, 1000)
        s.beacon(-60, 1000, 1000)
        s.door(25.0, 1000, 1050)
        assertEquals(25.0, s.cue(1050)!!.angle!!, 0.01)
        s.heading(55.0, 1550, 1550)
        assertEquals(-20.0, s.cue(1550)!!.angle!!, 0.01)
        s.beacon(-60, 3550, 3550)
        s.heading(60.0, 4940, 4950)
        assertEquals(-25.0, s.cue(4950)!!.angle!!, 0.01)
        assertNull(s.cue(5000))
    }

    @Test fun staleFramesAndMissingHeadingsCannotLockDirection() {
        val s = PassengerDoorSignal()
        s.beacon(-60, 1000, 1000)
        s.door(-25.0, 990, 1030)
        assertEquals(-25.0, s.cue(1040)!!.angle!!, 0.01)
        s.door(55.0, 980, 1050)
        assertNull(s.cue(2050))
        s.door(5.0, 1000, 2600)
        assertNull(s.cue(2600))
        s.clearDoor()
        assertNull(s.cue(2601))
    }

    @Test fun passengerUsesBinauralOnlyForDirectionalDoor() {
        assertEquals(ToneRenderMode.MONO_TARGET, selectToneRenderMode("passenger_door", null))
        assertEquals(ToneRenderMode.DOOR_DEMO_BINAURAL, selectToneRenderMode("passenger_door", -25.0))
    }
}
