import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/local_vision/vision_codec.dart';
import 'package:mobi_passenger_app/src/services/accepted_ride_beacon.dart';
import 'package:mobi_passenger_app/src/services/native_directional_cue_output.dart';
import 'package:mobi_passenger_app/src/services/passenger_bus_guide.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/vision_screen_audio.dart';

import 'local_vision_test.dart' as camera;
import 'native_android_audio_test.dart' as native;
import 'passenger_bus_guide_test.dart' show record;
import 'vision_observation_tts_test.dart' show FakeTts;

class _Fixture {
  _Fixture() {
    engine = SpatialVerificationEngine(
        NativeDirectionalCueOutput(port: native.Port()), tts);
    priority = SpeechPriorityCoordinator(engine);
    audio = VisionScreenAudio(
      priority: priority,
      engine: engine,
      sessionGeneration: 'approved',
      isCurrent: () => true,
      externalDirection: true,
      horizontalFovDegrees: 60,
      nowMicros: () => micros,
    );
    guide = PassengerBusGuide(
      visualOnly: true,
      lookup: () async => AcceptedRide.read(record, 'req711'),
      current: () => true,
      macs: (_) async => {},
      command: (name, args) async => events.add((name, args)),
    );
    // Use the same object/mute handoff as the native camera page.
    audio.addListener(() {
      if (guide.spokenClass != audio.spokenObjectClass) guide.clearDoor();
      guide.spokenClass = audio.spokenObjectClass;
      guide.previewBusy(audio.busy);
    });
    guide.start();
    audio.setEnabled(true);
  }

  final tts = FakeTts();
  final events = <(String, Map<String, Object?>)>[];
  late final SpatialVerificationEngine engine;
  late final SpeechPriorityCoordinator priority;
  late final VisionScreenAudio audio;
  late final PassengerBusGuide guide;
  int micros = 0, frames = 0;

  void frame({String? object = 'bus_door', double x = .4}) {
    final observation = LocalObservation(
      camera.frame(++frames),
      Uint8List(0),
      object == null ? [] : [LocalBox(object, .9, x, .2, .2, .3)],
      2,
      2,
      1,
      2,
    );
    final result = observation.toDetectionResult();
    guide.frame(result, DateTime.now(), 60);
    audio.observe(result, age: Duration.zero);
  }

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }
  }

  Future<void> recognizeDoor(WidgetTester tester) async {
    await flush(tester);
    frame();
    await flush(tester);
    expect(tts.spoken, ['버스 문이 인식되었습니다.']);
    expect(guide.spokenClass, isNull);
    tts.finish();
    await flush(tester);
    expect(guide.spokenClass, 'bus_door');
    events.clear();
  }

  Future<void> dispose() async {
    audio.dispose();
    guide.dispose();
    priority.dispose();
    await engine.dispose();
  }
}

void main() {
  testWidgets(
      'door moving left right and center keeps speech silent and angle active',
      (t) async {
    final f = _Fixture();
    try {
      await f.recognizeDoor(t);
      for (final position in [(0.1, -18.0), (0.7, 18.0), (0.4, 0.0)]) {
        // Exceed the old cooldown so it cannot hide the repeated announcement.
        f.micros += const Duration(seconds: 9).inMicroseconds;
        f.frame(x: position.$1);
        await f.flush(t);
        expect(f.tts.spoken, hasLength(1));
        expect(f.events.last.$1, 'frame');
        expect(f.events.last.$2['angle'], closeTo(position.$2, .001));
        expect(f.audio.busy, isFalse);
        expect(f.guide.spokenClass, 'bus_door');
      }
      expect(
          f.events.any((e) => e.$1 == 'mute' || e.$1 == 'clearDoor'), isFalse);
    } finally {
      await f.dispose();
    }
  });

  testWidgets(
      'door briefly out of view resumes center cue without another announcement',
      (t) async {
    final f = _Fixture();
    try {
      await f.recognizeDoor(t);
      f.frame(x: .1);
      f.frame(object: null);
      expect(f.events.last.$2['angle'], isNull);
      f.micros += const Duration(seconds: 9).inMicroseconds;
      f.frame();
      await f.flush(t);
      expect(f.tts.spoken, hasLength(1));
      expect(f.events.last.$1, 'frame');
      expect(f.events.last.$2['angle'], 0.0);
      expect(f.audio.busy, isFalse);
      expect(
          f.events.any((e) => e.$1 == 'mute' || e.$1 == 'clearDoor'), isFalse);
    } finally {
      await f.dispose();
    }
  });

  testWidgets(
      'a new object kind and a restarted camera still announce before cueing',
      (t) async {
    final f = _Fixture();
    try {
      await f.recognizeDoor(t);
      f.micros += const Duration(seconds: 9).inMicroseconds;
      f.frame(object: 'pole');
      await f.flush(t);
      expect(f.tts.spoken.last, '기둥이 인식되었습니다.');
      expect(f.guide.spokenClass, isNull);
      expect(
          f.events.any((e) => e.$1 == 'mute' && e.$2['value'] == true), isTrue);
      f.tts.finish();
      await f.flush(t);
      expect(f.guide.spokenClass, 'pole');

      await f.audio.stop();
      expect(f.guide.spokenClass, isNull);
      f.audio.setEnabled(true);
      f.frame(object: 'pole');
      await f.flush(t);
      expect(f.tts.spoken, hasLength(3));
      expect(f.guide.spokenClass, isNull);
      f.tts.finish();
      await f.flush(t);
      expect(f.guide.spokenClass, 'pole');
    } finally {
      await f.dispose();
    }
  });

  testWidgets(
      'unsuccessful speech does not mark the object as already announced',
      (t) async {
    final f = _Fixture();
    try {
      await f.flush(t);
      f.tts.fail = true;
      f.frame();
      await f.flush(t);
      expect(f.guide.spokenClass, isNull);
      f.tts.fail = false;
      f.micros += const Duration(seconds: 9).inMicroseconds;
      f.frame();
      await f.flush(t);
      expect(f.tts.spoken, ['버스 문이 인식되었습니다.']);
      f.tts.finish();
      await f.flush(t);
      expect(f.guide.spokenClass, 'bus_door');
    } finally {
      await f.dispose();
    }
  });
}
