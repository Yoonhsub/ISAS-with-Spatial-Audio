import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/voice_live/live_caption_controller.dart';
import 'package:mobi_passenger_app/src/features/voice_live/live_speech.dart';
import 'package:mobi_passenger_app/src/features/voice_live/live_voice_controller.dart';
import 'package:mobi_passenger_app/src/features/voice_live/voice_turn_state.dart';

class ControlledRecognizer extends LiveSpeechRecognizer {
  ControlledRecognizer({this.available = true});
  final bool available;
  bool listening = false;
  void Function(String)? status;
  void Function(String, bool)? transcript;
  @override
  bool get isListening => listening;
  @override
  bool get isContinuous => false;
  @override
  bool get needsRecovery => false;
  @override
  Future<bool> start(
      {required String localeId,
      required void Function(String, bool) onResult,
      required void Function(String) onState}) async {
    status = onState;
    transcript = onResult;
    return available;
  }

  void emit(String value) {
    listening = value == 'listening';
    status?.call(value);
  }

  @override
  void setActive(bool active) {
    if (!active) listening = false;
  }

  @override
  bool resume() => available;
  @override
  Future<void> stop() async {
    listening = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LiveVoiceController controller(ControlledRecognizer recognizer,
      {LiveUtteranceProcessor? processor, LiveSpeak? speak}) {
    final captions = LiveCaptionController();
    final value = LiveVoiceController(
      captions: captions,
      recognizer: recognizer,
      processor: processor ??
          (text, {onThought}) async =>
              const LiveProcessResult(spokenText: '응답'),
      speak: speak ?? (text, {onStart}) async {},
      stopAudio: () async {},
      onNavigate: () {},
      onEnd: () {},
    );
    addTearDown(() async {
      await value.stop();
      value.dispose();
      captions.dispose();
    });
    return value;
  }

  test('listening indicator waits for recognizer readiness and clears on loss',
      () async {
    final recognizer = ControlledRecognizer();
    final voice = controller(recognizer);
    await voice.start();
    expect(voice.state.value, VoiceTurnState.listening);
    expect(voice.microphoneActive.value, isFalse);
    recognizer.emit('listening');
    expect(voice.microphoneActive.value, isTrue);
    recognizer.emit('notListening');
    expect(voice.microphoneActive.value, isFalse);
    recognizer.emit('listening');
    expect(voice.microphoneActive.value, isTrue);
    await voice.setMuted(true);
    expect(voice.microphoneActive.value, isFalse);
  });

  test('failed microphone initialization never displays an active microphone',
      () async {
    final voice = controller(ControlledRecognizer(available: false));
    await voice.start();
    expect(voice.microphoneActive.value, isFalse);
    expect(voice.microphoneUnavailable.value, isTrue);
    expect(voice.state.value, VoiceTurnState.idle);
  });

  test(
      'processing and playback close the listening indicator until manual restart',
      () async {
    final recognizer = ControlledRecognizer();
    final response = Completer<LiveProcessResult>();
    final playback = Completer<void>();
    final voice = controller(recognizer,
        processor: (text, {onThought}) => response.future,
        speak: (text, {onStart}) => playback.future);
    await voice.start();
    recognizer.emit('listening');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    recognizer.transcript!('병원 가고싶은데 몇 번 버스 타', true);
    expect(voice.state.value, VoiceTurnState.thinking);
    expect(voice.microphoneActive.value, isFalse);
    recognizer.emit('error'); // Late callback from the input cancelled for processing.
    expect(voice.microphoneUnavailable.value, isFalse);
    response.complete(const LiveProcessResult(spokenText: '정류장을 선택해 주세요.'));
    await Future<void>.delayed(Duration.zero);
    expect(voice.state.value, VoiceTurnState.speaking);
    expect(voice.microphoneActive.value, isFalse);
    playback.complete();
    await Future<void>.delayed(Duration.zero);
    expect(voice.state.value, VoiceTurnState.idle);
    expect(voice.microphoneActive.value, isFalse);
    voice.handleMicTap();
    await Future<void>.delayed(Duration.zero);
    recognizer.emit('listening');
    expect(voice.microphoneActive.value, isTrue);
    await voice.stop();
  });
}
