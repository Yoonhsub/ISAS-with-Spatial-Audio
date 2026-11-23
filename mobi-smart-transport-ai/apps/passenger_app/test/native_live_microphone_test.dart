import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/voice_live/live_caption_controller.dart';
import 'package:mobi_passenger_app/src/features/voice_live/live_speech_stub.dart';
import 'package:mobi_passenger_app/src/features/voice_live/live_voice_controller.dart';
import 'package:mobi_passenger_app/src/features/voice_live/voice_turn_state.dart';

// Exercise the real speech_to_text singleton and native adapter, replacing only
// the Android method channel so callback ordering matches the device plugin.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugin.csdcorp.com/speech_to_text');
  final messenger = binding.defaultBinaryMessenger;
  var listens = 0;
  var failListen = false;
  Completer<void>? cancelGate;

  Future<void> emit(String method, Object argument) async {
    final done = Completer<void>();
    // The native platform calls Dart through this channel.
    // ignore: deprecated_member_use
    await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall(method, argument)),
        (_) => done.complete());
    await done.future;
  }

  Future<void> status(String value) => emit('notifyStatus', value);
  Future<void> error(String value) =>
      emit('notifyError', jsonEncode({'errorMsg': value, 'permanent': true}));

  setUp(() {
    listens = 0;
    failListen = false;
    cancelGate = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'initialize':
        case 'has_permission':
          return true;
        case 'listen':
          listens++;
          if (failListen) throw PlatformException(code: 'audio_unavailable');
          await status('listening');
          return true;
        case 'cancel':
        case 'stop':
          await cancelGate?.future;
          await status('notListening');
          await status('doneNoResult');
          return true;
      }
      return null;
    });
  });

  LiveVoiceController controller({List<String>? utterances}) {
    final captions = LiveCaptionController();
    final voice = LiveVoiceController(
      captions: captions,
      processor: (text, {onThought}) async {
        utterances?.add(text);
        return const LiveProcessResult(spokenText: '정류장을 선택해 주세요.');
      },
      speak: (text, {onStart}) async {},
      stopAudio: () async {},
      onNavigate: () {},
      onEnd: () {},
    );
    addTearDown(() async {
      await voice.stop();
      voice.dispose();
      captions.dispose();
    });
    return voice;
  }

  Future<void> settleStart() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await Future<void>.delayed(Duration.zero);
  }

  test('reopening voice page rebinds singleton status and error callbacks',
      () async {
    final first = controller();
    final firstStart = first.start();
    await settleStart();
    await firstStart;
    expect(first.microphoneActive.value, isTrue);
    await first.stop();
    final second = controller();
    final secondStart = second.start();
    await settleStart();
    await secondStart;
    expect(second.microphoneActive.value, isTrue);
    expect(first.microphoneActive.value, isFalse);
    await error('error_permission');
    expect(second.microphoneUnavailable.value, isTrue);
    expect(second.state.value, VoiceTurnState.idle);
    await second.stop();
  });

  test('terminal callback burst never restarts; a new tap opens once',
      () async {
    final voice = controller();
    final start = voice.start();
    await settleStart();
    await start;
    await status('notListening');
    await status('doneNoResult');
    await error('error_busy');
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(listens, 1);
    expect(voice.microphoneActive.value, isFalse);
    expect(voice.state.value, VoiceTurnState.idle);
    voice.handleMicTap();
    voice.handleMicTap();
    voice.handleMicTap();
    await settleStart();
    expect(listens, 2);
    expect(voice.microphoneActive.value, isTrue);
    expect(voice.microphoneUnavailable.value, isFalse);
    await voice.stop();
  });

  test('final transcript after native done reaches the processor once',
      () async {
    final utterances = <String>[];
    final voice = controller(utterances: utterances);
    final start = voice.start();
    await settleStart();
    await start;
    // The controller guards real-time callbacks immediately following resume.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await status('notListening');
    await status('doneNoResult');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await emit(
        'textRecognition',
        jsonEncode({
          'alternates': [
            {'recognizedWords': '충북대학교병원 가고싶은데 몇 번 버스 타', 'confidence': 1.0}
          ],
          'finalResult': true,
        }));
    await Future<void>.delayed(Duration.zero);
    expect(utterances, ['충북대학교병원 가고싶은데 몇 번 버스 타']);
    expect(listens, 1);
    expect(voice.state.value, VoiceTurnState.idle);
    voice.handleMicTap();
    await settleStart();
    expect(listens, 2);
    expect(voice.microphoneActive.value, isTrue);
    await voice.stop();
  });

  test('silence returns to idle without flashing or automatic retries',
      () async {
    final voice = controller();
    final start = voice.start();
    await settleStart();
    await start;
    await status('notListening');
    await status('doneNoResult');
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(voice.state.value, VoiceTurnState.idle);
    expect(voice.microphoneUnavailable.value, isFalse);
    expect(listens, 1);
    await voice.stop();
  });

  test('resume waits for cancellation and coalesces repeated taps', () async {
    final recognizer = LiveSpeechRecognizer();
    final start = recognizer.start(
        localeId: 'ko_KR', onResult: (_, __) {}, onState: (_) {});
    await settleStart();
    expect(await start, isTrue);
    cancelGate = Completer<void>();
    recognizer.setActive(false);
    recognizer.resume();
    recognizer.resume();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(listens, 1);
    cancelGate!.complete();
    cancelGate = null;
    await settleStart();
    expect(listens, 2);
    expect(recognizer.isListening, isTrue);
    await recognizer.stop();
  });

  test('native start failure is visible and can be retried manually', () async {
    failListen = true;
    final voice = controller();
    final start = voice.start();
    await settleStart();
    await start;
    expect(voice.microphoneActive.value, isFalse);
    expect(voice.microphoneUnavailable.value, isTrue);
    expect(voice.state.value, VoiceTurnState.idle);
    failListen = false;
    voice.handleMicTap();
    await settleStart();
    expect(voice.microphoneActive.value, isTrue);
    await voice.stop();
  });
}
