package com.mobi.passenger

/** Selects the existing target fallback or an explicitly requested door demo. */
internal enum class ToneRenderMode {
    DOOR_DEMO_BINAURAL,
    WARNING_HRTF,
    TARGET_DIRECTIONAL_FALLBACK,
    MONO_TARGET,
    MONO_WARNING,
}

internal fun selectToneRenderMode(pattern: String, azimuth: Double?): ToneRenderMode {
    require(pattern == "target" || pattern == "warning" || pattern == "door_demo" || pattern == "passenger_door")
    require(azimuth == null || (azimuth.isFinite() && azimuth in -180.0..180.0))
    require(pattern != "door_demo" || azimuth != null)
    return when {
        pattern == "passenger_door" && azimuth == null -> ToneRenderMode.MONO_TARGET
        pattern == "passenger_door" || pattern == "door_demo" -> ToneRenderMode.DOOR_DEMO_BINAURAL
        pattern == "warning" && azimuth != null -> ToneRenderMode.WARNING_HRTF
        pattern == "target" && azimuth != null -> ToneRenderMode.TARGET_DIRECTIONAL_FALLBACK
        pattern == "warning" -> ToneRenderMode.MONO_WARNING
        else -> ToneRenderMode.MONO_TARGET
    }
}
