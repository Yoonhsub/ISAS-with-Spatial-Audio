package com.mobi.passenger

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PhoneCameraHeadingTest {
    @Test fun rearLensYawIsLeftPositiveAndIgnoresVerticalTilt() {
        assertEquals(0.0, rearCameraYaw(0.0, -1.0)!!, 1e-6)
        assertEquals(-90.0, rearCameraYaw(-1.0, 0.0)!!, 1e-6)
        assertEquals(90.0, rearCameraYaw(1.0, 0.0)!!, 1e-6)
        assertEquals(-45.0, rearCameraYaw(-0.4, -0.4)!!, 1e-6)
        assertNull(rearCameraYaw(0.0, 0.0))
    }
}
