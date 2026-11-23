import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/voice_live/live_voice_page.dart';
import 'package:mobi_passenger_app/src/pages/v3_guidance_page.dart';
import 'package:mobi_passenger_app/src/services/local_guidance_runtime.dart';
import 'package:mobi_passenger_app/src/services/session_guidance_audio.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/widgets/chat_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'confirmed_passenger_ride_test.dart'
    show RideFixture, RecordingSpeech, audioChannels, frames;

void main() {
  testWidgets('live route questions remain voice-only after returning and reopening',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    audioChannels();
    final f = RideFixture();
    final priority = SpeechPriorityCoordinator(RecordingSpeech());
    addTearDown(priority.dispose);
    final runtime = LocalGuidanceRuntime(
        client: f.guidance,
        rideApi: f.api,
        auth: f.auth,
        captureGuard: () => () => f.auth.currentAccount?.uid == 'owner',
        priority: priority,
        audio: SessionGuidanceAudio(priority: priority),
        controls: (_, __, ___) => const SizedBox());
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: V3GuidancePage(
            agentName: '모비', dataMode: 'live',
            onReturnToModeSelection: () {},
            sharedSession: f.shared, localRuntime: runtime)));
    await frames(tester);

    for (var attempt = 0; attempt < 2; attempt++) {
      expect(find.text('채팅으로 질문하기'), findsNothing);
      expect(find.byType(ChatOverlay), findsNothing);
      expect(find.byType(TextField), findsNothing);
      final button = find.text('음성으로 질문하기');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 80));
      if (find.byType(LiveVoicePage).evaluate().isEmpty) await tester.tap(button);
      await frames(tester);
      final voice = tester.widget<LiveVoicePage>(find.byType(LiveVoicePage));
      final response = await voice.processor('711번');
      expect(response.spokenText, contains('711번 버스를 타세요'));
      expect(f.shared.state?.sessionId, 's');
      voice.onExit([], navigated: false);
      nav.currentState!.pop();
      await frames(tester);
    }
    expect(f.commands, ['711번', '711번']);
    expect(f.bodies, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
  });
}
