import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/src/local_vision/native_local_vision_page.dart';
import 'package:mobi_passenger_app/src/pages/passenger_presentation.dart';
import 'package:mobi_passenger_app/src/pages/v3_guidance_page.dart';
import 'package:mobi_passenger_app/src/services/local_guidance_runtime.dart';
import 'package:mobi_passenger_app/src/services/ride_creation_intent.dart';
import 'package:mobi_passenger_app/src/services/session_guidance_audio.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';

import 'confirmed_passenger_ride_test.dart'
    show RideFixture, audioChannels, frames;
import 'guidance_reconnect_test.dart' show SilentSpeech;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<RideFixture> open(WidgetTester tester, String status,
      {bool wrongOwner = false, bool wrongRequest = false, Completer<void>? holdRead}) async {
    audioChannels();
    final fixture = RideFixture()
      ..guidanceState = 'WAITING_FOR_BUS'
      ..decision = status;
    fixture.holdRead = holdRead;
    if (wrongOwner) fixture.recordOwner = 'another-passenger';
    if (wrongRequest) fixture.responseId = 'another-request';
    fixture.bodies.add({
      'userId': 'owner',
      'routeId': 'CJB270009500',
      'busNo': '711',
      'stopId': 'CJB271000129'
    });
    final store = RideCreationIntentStore();
    await store.rememberRequest('owner', 'ride-711');
    await store.bindSession('owner', 's', 'ride-711');
    final priority = SpeechPriorityCoordinator(SilentSpeech());
    addTearDown(priority.dispose);
    final runtime = LocalGuidanceRuntime(
      client: fixture.guidance,
      rideApi: fixture.api,
      auth: fixture.auth,
      captureGuard: () => () => fixture.auth.currentAccount?.uid == 'owner',
      priority: priority,
      audio: SessionGuidanceAudio(priority: priority),
      controls: (_, __, ___) => const SizedBox(),
    );
    await tester.pumpWidget(MaterialApp(
      home: PassengerLanding(onOnline: () {}, speech: priority),
      routes: {
        '/online-vision': (_) => V3GuidancePage(
            agentName: '모비',
            dataMode: 'live',
            visionOnly: true,
            autoStartCamera: true,
            localRuntime: runtime,
            sharedSession: fixture.shared,
            onReturnToModeSelection: () {})
      },
    ));
    await frames(tester);
    await tester.ensureVisible(find.text('장애물 탐지'));
    await tester.tap(find.text('장애물 탐지')); // Exactly one home activation.
    await frames(tester);
    return fixture;
  }

  testWidgets('one home tap opens the accepted camera with automatic start',
      (tester) async {
    final fixture = await open(tester, 'ACCEPTED');
    expect(find.byType(LocalVisionPage), findsOneWidget);
    final camera = tester.widget<LocalVisionPage>(find.byType(LocalVisionPage));
    expect(camera.autoStart, isTrue);
    expect(camera.bundledModel, isTrue);
    expect(camera.sessionCurrent!(), isTrue);
    // A cancellation during model preparation must block before hardware starts.
    fixture.decision = 'CANCELLED';
    await expectLater(
        camera.beforeStart!(), throwsA(isA<VisionLeaseException>()));
    expect(camera.sessionCurrent!(), isFalse);
    final navigator =
        Navigator.of(tester.element(find.byType(LocalVisionPage)));
    navigator.pop();
    await frames(tester);
    expect(find.byType(LocalVisionPage),
        findsNothing); // No automatic reopen loop.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    await frames(tester);
  });

  testWidgets('leaving during approval lookup never opens a late camera', (tester) async {
    final gate = Completer<void>();
    await open(tester, 'ACCEPTED', holdRead: gate);
    expect(find.byType(LocalVisionPage), findsNothing);
    Navigator.of(tester.element(find.byType(V3GuidancePage))).pop();
    gate.complete();
    await frames(tester);
    expect(find.byType(LocalVisionPage), findsNothing);
    expect(find.byType(PassengerLanding), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  });

  for (final status in ['WAITING', 'DENIED', 'CANCELLED']) {
    testWidgets('$status request does not open a camera automatically',
        (tester) async {
      await open(tester, status);
      expect(find.byType(LocalVisionPage), findsNothing);
      expect(find.textContaining('아직 승인된 탑승 요청이 없습니다.'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      await frames(tester);
    });
  }

  for (final wrongOwner in [true, false]) {
    testWidgets(
        'automatic camera rejects mismatched ${wrongOwner ? "owner" : "request"}',
        (tester) async {
      await open(tester, 'ACCEPTED',
          wrongOwner: wrongOwner, wrongRequest: !wrongOwner);
      expect(find.byType(LocalVisionPage), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      await frames(tester);
    });
  }
}
