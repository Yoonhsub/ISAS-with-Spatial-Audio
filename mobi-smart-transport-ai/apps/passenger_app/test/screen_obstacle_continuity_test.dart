import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/local_vision/vision_codec.dart';
import 'package:mobi_passenger_app/src/services/native_directional_cue_output.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/vision_screen_audio.dart';

import 'native_android_audio_test.dart' as native;
import 'vision_observation_tts_test.dart' as speech;
import 'vision_screen_audio_test.dart' as fixtures;

void main() {
  const left = LocalBox('pole', .95, .04, .48, .2, .4);
  const nearLeft = LocalBox('pole', .92, .06, .49, .2, .4);
  const center = LocalBox('pole', .94, .4, .49, .2, .4);
  const right = LocalBox('pole', .94, .72, .49, .2, .4);
  const disjointLeft = LocalBox('pole', .94, .07, .01, .2, .36);
  const trunk = LocalBox('tree_trunk', .94, .04, .48, .2, .4);
  for (final name in [
    'left jitter',
    'center',
    'right',
    'continuous detection over two seconds',
    'direction change',
    'vanished then returned',
    'replaced in same region',
    'different obstacle class',
    'gap at freshness deadline',
    'duplicate frame',
    'malformed frame then returned',
    'low confidence',
    'older capture arrived late',
    'session ended',
    'STOP',
    'priority hold',
    'frame replaced before TTS admission'
  ]) {
    testWidgets('pending obstacle ping: $name', (tester) async {
      final tts = speech.FakeTts();
      final port = native.Port();
      final engine = SpatialVerificationEngine(
          NativeDirectionalCueOutput(port: port), tts);
      final priority = SpeechPriorityCoordinator(engine);
      var ticks = 0;
      var sessionCurrent = true;
      final audio = VisionScreenAudio(
        priority: priority,
        engine: engine,
        sessionGeneration: 'camera',
        isCurrent: () => sessionCurrent,
        nowMicros: () => ticks,
        prioritizeByDistance: true,
        confirmationFrames: 1,
      );
      Future<void> flush() async {
        for (var i = 0; i < 20; i++) {
          await tester.pump();
        }
      }

      Map<String, Object?> make(List<LocalBox> boxes) =>
          fixtures.detection(ticks, boxes: boxes).toDetectionResult();
      Future<void> advance(int ms) async {
        ticks += ms * 1000;
        await tester.pump(Duration(milliseconds: ms));
      }

      void submit(List<LocalBox> boxes, {Duration age = Duration.zero}) =>
          audio.observe(make(boxes), age: age);
      final initialBox = name == 'center'
          ? center
          : name == 'right'
              ? right
              : left;
      audio.setEnabled(true);
      final first = make([initialBox]);
      audio.observe(first, age: Duration.zero);
      if (name == 'frame replaced before TTS admission') submit([initialBox]);
      await flush();
      expect(tts.spoken.length,
          name == 'frame replaced before TTS admission' ? 0 : 1);
      expect(port.active, isNull);
      await advance(250);
      switch (name) {
        case 'left jitter':
          submit([nearLeft]);
          break;
        case 'center':
        case 'right':
          submit([initialBox]);
          break;
        case 'continuous detection over two seconds':
          for (var i = 0; i < 9; i++) {
            submit([nearLeft]);
            await advance(250);
          }
          break;
        case 'direction change':
          submit([right]);
          break;
        case 'vanished then returned':
          submit([]);
          submit([nearLeft]);
          break;
        case 'replaced in same region':
          submit([disjointLeft]);
          break;
        case 'different obstacle class':
          submit([trunk]);
          break;
        case 'low confidence':
          submit([const LocalBox('pole', .01, .04, .48, .2, .4)]);
          break;
        case 'gap at freshness deadline':
          await advance(1750);
          submit([nearLeft]);
          break;
        case 'older capture arrived late':
          submit([nearLeft], age: const Duration(milliseconds: 300));
          break;
        case 'duplicate frame':
          audio.observe(first, age: Duration.zero);
          await advance(1750);
          break;
        case 'malformed frame then returned':
          audio.observe({
            ...make([left]),
            'imageSize': null
          }, age: Duration.zero);
          submit([nearLeft]);
          break;
        case 'session ended':
          sessionCurrent = false;
          break;
        case 'STOP':
          await audio.stop();
          submit([left]);
          break;
        case 'priority hold':
          await audio.toggleHold();
          break;
      }
      tts.finish();
      await flush();
      final expected = switch (name) {
        'left jitter' || 'continuous detection over two seconds' => 'LEFT',
        'center' => 'CENTER',
        'right' => 'RIGHT',
        _ => null,
      };
      expect(port.active?['direction'], expected);
      if (expected != null) {
        port.finish();
        await flush();
        expect(audio.completed, 1);
        expect(tts.spoken, hasLength(1));
      } else {
        expect(audio.completed, 0);
      }
      await audio.stop();
      audio.dispose();
      await engine.dispose();
      priority.dispose();
    });
  }
}
