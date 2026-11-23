import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/pages/v3_guidance_page.dart';
import 'package:mobi_passenger_app/src/features/voice_live/live_voice_page.dart';
import 'package:mobi_passenger_app/src/services/shared_guidance_session.dart';
import 'package:mobi_passenger_app/src/widgets/described_action.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/src/models/v3_guidance_models.dart';
import 'package:mobi_passenger_app/src/services/local_guidance_runtime.dart';
import 'package:mobi_passenger_app/src/services/session_guidance_audio.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';

import 'guidance_reconnect_test.dart'
    show DemoAuth, SilentSpeech, RecoveringClient;
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';

class VoiceReconnectClient extends RecoveringClient {
  final voiceSessions = <String>[];
  @override
  Future<V3GuidanceState> resumeSession({required String sessionId}) async =>
      throw const V3ApiException('session access denied', statusCode: 403);

  @override
  Future<V3AgentResponse> converse(
      {required String sessionId,
      required String wakeWord,
      required String utterance,
      String? mode,
      double? originLat,
      double? originLng,
      String? nluProvider}) async {
    voiceSessions.add(sessionId);
    return V3AgentResponse.fromJson(
        {'sessionId': sessionId, 'message': '응답 완료'});
  }
}

void main() {
  void mockAudio() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        SystemChannels.platform, (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global/events'),
        (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['playerId'];
        messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null);
      }
      return null;
    });
  }

  testWidgets(
      'voice reconnects after a denied resume and never sends a turn for a lost session',
      (tester) async {
    mockAudio();
    final client = VoiceReconnectClient();
    final shared = SharedGuidanceSession()
      ..bind('owner|${client.baseUrl}|live')
      ..state =
          V3GuidanceState.fromJson({'sessionId': 'expired', 'state': 'IDLE'});
    final priority = SpeechPriorityCoordinator(SilentSpeech());
    addTearDown(priority.dispose);
    final runtime = LocalGuidanceRuntime(
        client: client,
        auth: DemoAuth(),
        captureGuard: () => () => true,
        priority: priority,
        audio: SessionGuidanceAudio(priority: priority),
        controls: (_, __, ___) => const SizedBox());
    await tester.pumpWidget(MaterialApp(
        home: V3GuidancePage(
            agentName: 'mobi',
            onReturnToModeSelection: () {},
            dataMode: 'live',
            sharedSession: shared,
            localRuntime: runtime)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('서버 다시 연결'), findsOneWidget);
    Future<void> tapVoice() async {
      final button = find.byWidgetPredicate(
          (widget) => widget is DescribedAction && widget.label == '음성으로 질문하기');
      for (var i = 0;
          i < 8 && tester.widget<DescribedAction>(button).onActivate == null;
          i++) {
        await tester.pump(const Duration(seconds: 3));
      }
      tester.widget<DescribedAction>(button).onActivate!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await tapVoice(); // First explicit connection retry fails.
    expect(client.starts, 1);
    expect(find.byType(LiveVoicePage), findsNothing);
    expect(client.voiceSessions, isEmpty);
    await tapVoice();
    expect(client.starts, 2);
    final voice = tester.widget<LiveVoicePage>(find.byType(LiveVoicePage));
    expect((await voice.processor('안녕하세요')).spokenText, '응답 완료');
    expect(client.voiceSessions, ['recovered']);
    shared.clear();
    expect((await voice.processor('다음 질문')).spokenText, contains('다시 연결'));
    expect(client.voiceSessions, ['recovered']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 35));
  });
}
