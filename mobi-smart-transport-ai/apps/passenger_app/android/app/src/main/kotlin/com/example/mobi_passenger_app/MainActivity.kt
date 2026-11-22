package com.example.mobi_passenger_app

import com.mobi.passenger.HardwareBusActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : HardwareBusActivity() {
    private var door: com.mobi.passenger.PassengerDoorAudio? = null
    private var audio: LocalStereoCue? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        door = com.mobi.passenger.PassengerDoorAudio(this, engine.dartExecutor.binaryMessenger)
        audio = LocalStereoCue(this, MethodChannel(engine.dartExecutor.binaryMessenger, "mobi/local_android_audio"))
    }
    override fun onPause() {
        door?.stop()
        audio?.suspendOutput()
        super.onPause()
    }
    override fun onDestroy() {
        door?.close()
        door = null
        audio?.close()
        audio = null
        super.onDestroy()
    }
}
