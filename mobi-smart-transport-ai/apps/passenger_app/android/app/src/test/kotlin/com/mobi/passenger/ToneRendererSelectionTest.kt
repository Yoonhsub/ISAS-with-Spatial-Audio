package com.mobi.passenger

import org.junit.Assert.assertEquals
import org.junit.Test

class ToneRendererSelectionTest {
    @Test fun explicitDoorPatternSelectsDoorRenderer() {
        assertEquals(
            ToneRenderMode.DOOR_DEMO_BINAURAL,
            selectToneRenderMode("door_demo", 32.0),
        )
    }

    @Test fun ordinaryDirectionalTargetKeepsExistingPanFallback() {
        assertEquals(
            ToneRenderMode.TARGET_DIRECTIONAL_FALLBACK,
            selectToneRenderMode("target", 32.0),
        )
    }

    @Test fun measuredWarningHrtfDoesNotSelectDoorRenderer() {
        assertEquals(
            ToneRenderMode.WARNING_HRTF,
            selectToneRenderMode("warning", -18.0),
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun doorDemoWithoutVerifiedAngleIsRejected() {
        selectToneRenderMode("door_demo", null)
    }
}
