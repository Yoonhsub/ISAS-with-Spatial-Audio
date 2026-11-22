package com.mobi.passenger

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import kotlin.math.atan2
import kotlin.math.hypot

internal class PhoneCameraHeading(context: Context) : EventChannel.StreamHandler, SensorEventListener {
    private val manager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val matrix = FloatArray(9)
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stop()
        val sensor = manager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
            ?: manager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        sink = events
        if (sensor == null || !manager.registerListener(this, sensor, 40_000)) {
            events.error("NO_HEADING", "내장 회전 센서를 사용할 수 없습니다", null)
            stop()
        }
    }

    override fun onSensorChanged(event: SensorEvent) {
        SensorManager.getRotationMatrixFromVector(matrix, event.values)
        val yaw = rearCameraYaw(matrix[2].toDouble(), matrix[5].toDouble())
        val ageMs = (SystemClock.elapsedRealtimeNanos() - event.timestamp) / 1_000_000
        sink?.success(if (yaw == null || ageMs !in 0L..250L) null else
            mapOf("yaw" to yaw, "at" to System.currentTimeMillis() - ageMs))
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    override fun onCancel(arguments: Any?) = stop()
    fun stop() {
        manager.unregisterListener(this)
        sink = null
    }
}

// The rear lens looks along device -Z. Project it into the world's horizontal
// plane, with left turns positive, independent of portrait/landscape roll.
internal fun rearCameraYaw(deviceZEast: Double, deviceZNorth: Double): Double? =
    if (hypot(deviceZEast, deviceZNorth) < 0.25) null
    else Math.toDegrees(atan2(deviceZEast, -deviceZNorth))
