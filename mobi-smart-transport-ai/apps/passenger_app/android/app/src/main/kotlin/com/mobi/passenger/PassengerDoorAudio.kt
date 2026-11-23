package com.mobi.passenger

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlin.math.atan2
import kotlin.math.hypot

internal class PassengerDoorAudio(context: Context, messenger: BinaryMessenger) : SensorEventListener {
    private val channel = MethodChannel(messenger, "mobi.passenger/accepted-door")
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val debugTiming = context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
    private val tone = ToneTestEngine(context)
    private val handler = Handler(Looper.getMainLooper())
    private val matrix = FloatArray(9)
    private var owner: String? = null
    private var signal = PassengerDoorSignal()
    private var muted = false
    private var playing = false
    private var retryAfter = 0L
    private val tick = object : Runnable {
        override fun run() {
            if (owner == null) return
            val now = SystemClock.elapsedRealtime()
            val cue = if (muted) null else signal.cue(now)
            if (cue == null) silence() else if (now >= retryAfter) try {
                val state = if (playing) tone.update(.707, .707, cue.headingAge, cue.interval, cue.beaconAge, "passenger_door", cue.angle)
                    else tone.start(.707, .707, cue.headingAge, cue.interval, cue.beaconAge, "passenger_door", cue.angle)
                playing = state["running"] == true
                if (!playing) retryAfter = now + 3000
            } catch (_: Exception) {
                silence()
                retryAfter = now + 3000
            }
            if (owner != null) handler.postDelayed(this, 100)
        }
    }
    init {
        channel.setMethodCallHandler { call, result ->
            try {
                val token = call.argument<String>("owner")
                require(!token.isNullOrEmpty())
                val now = SystemClock.elapsedRealtime()
                val at = now - (System.currentTimeMillis() - (call.argument<Number>("at")?.toLong() ?: System.currentTimeMillis()))
                if (call.method == "begin") {
                    stop()
                    owner = token
                    signal = PassengerDoorSignal(photoDemo = call.argument<Boolean>("photoDemo") == true, visualOnly = call.argument<Boolean>("visualOnly") == true)
                    muted = false
                    retryAfter = 0L
                    sensors.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)?.let {
                        sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
                    }
                    handler.post(tick)
                } else if (owner == token) {
                    when (call.method) {
                        "beacon" -> {
                            val raw = call.argument<Number>("rssi")!!.toInt()
                            signal.beacon(raw, at, now)
                            if (debugTiming) android.util.Log.d("MobiBeaconTiming",
                                "sampleMs=$at raw=$raw intervalMs=${signal.cue(now)?.interval}")
                        }
                        "frame" -> signal.door(call.argument<Number>("angle")?.toDouble(), at, now)
                        "visualArrival" -> {
                            signal.beginVisualGuidance()
                            if (signal.cue(now) == null) silence()
                        }
                        "clearDoor" -> signal.clearDoor()
                        "mute" -> { muted = call.argument<Boolean>("value") == true; if (muted) silence() }
                        "stop" -> stop()
                        else -> { result.notImplemented(); return@setMethodCallHandler }
                    }
                }
                result.success(null)
            } catch (e: Exception) { stop(); result.error("DOOR_AUDIO", e.message, null) }
        }
    }
    override fun onSensorChanged(event: SensorEvent) {
        if (owner == null) return
        SensorManager.getRotationMatrixFromVector(matrix, event.values)
        // Rear camera looks along -Z. Positive bearing is clockwise (screen right).
        val east = -matrix[2].toDouble()
        val north = -matrix[5].toDouble()
        val yaw = if (hypot(east, north) > 0.1) Math.toDegrees(atan2(east, north)) else null
        signal.heading(yaw, event.timestamp / 1_000_000, SystemClock.elapsedRealtime())
    }
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    private fun silence() { if (playing) tone.stop(); playing = false }
    fun stop() {
        owner = null
        handler.removeCallbacks(tick)
        sensors.unregisterListener(this)
        tone.stop()
        playing = false
    }
    fun close() { stop(); channel.setMethodCallHandler(null) }
}
