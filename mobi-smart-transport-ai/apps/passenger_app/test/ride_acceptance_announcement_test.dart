import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/src/pages/ride_request_panel.dart';
import 'package:mobi_passenger_app/src/services/ride_acceptance_announcement.dart';
import 'package:mobi_passenger_app/src/services/ride_creation_intent.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/widgets/described_action.dart';
import 'confirmed_passenger_ride_test.dart' show RideFixture, RecordingSpeech, frames;

class HeldSpeech extends RecordingSpeech {
  final completion = Completer<void>();
  @override
  Future<void> speak(String text) async {
    messages.add(text);
    await completion.future;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('accepted owned request speaks once across polling and reopening', (tester) async {
    final f = RideFixture();
    f.bodies.add({'userId': 'owner', 'routeId': 'r', 'busNo': '711', 'stopId': 's'});
    await RideCreationIntentStore().rememberRequest('owner', 'ride-711');
    final engine = RecordingSpeech();
    final speech = SpeechPriorityCoordinator(engine);
    addTearDown(speech.dispose);
    Widget page() => MaterialApp(home: ActionSpeechScope(speech: speech,
      child: RideRequestPanel(api: f.api, draft: null, session: f.auth, autoRefresh: true)));
    await tester.pumpWidget(page());
    await frames(tester);
    expect(engine.messages, isEmpty);
    f.decision = 'ACCEPTED';
    await tester.pump(const Duration(seconds: 5));
    await frames(tester);
    expect(engine.messages, [RideAcceptanceAnnouncement.message]);
    await tester.pump(const Duration(seconds: 10));
    await frames(tester);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    await tester.pumpWidget(page());
    await frames(tester);
    expect(engine.messages, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('foreign or mismatched acceptance cannot speak', (tester) async {
    final f = RideFixture()..decision = 'ACCEPTED';
    f.bodies.add({'userId': 'other-user', 'routeId': 'r', 'busNo': '711', 'stopId': 's'});
    await RideCreationIntentStore().rememberRequest('owner', 'ride-711');
    final engine = RecordingSpeech();
    final speech = SpeechPriorityCoordinator(engine);
    addTearDown(speech.dispose);
    await tester.pumpWidget(MaterialApp(home: ActionSpeechScope(speech: speech,
      child: RideRequestPanel(api: f.api, draft: null, session: f.auth, autoRefresh: true))));
    await frames(tester);
    expect(engine.messages, isEmpty);
    f.recordOwner = 'owner';
    f.responseId = 'another-request';
    await tester.pump(const Duration(seconds: 5));
    await frames(tester);
    expect(engine.messages, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  test('new transfer request announces independently; concurrent calls deduplicate', () async {
    final engine = HeldSpeech();
    final speech = SpeechPriorityCoordinator(engine);
    final owner = Object();
    Future<void> announce(String id) => RideAcceptanceAnnouncement.announce(
        uid: 'p', requestId: id, speech: speech, owner: owner, current: () => true);
    final first = announce('ride-1');
    await Future<void>.delayed(Duration.zero);
    await announce('ride-1');
    engine.completion.complete();
    await first;
    await announce('ride-2');
    expect(engine.messages, List.filled(2, RideAcceptanceAnnouncement.message));
    speech.dispose();
  });

  test('priority interruption defers acceptance until another valid poll', () async {
    final engine = RecordingSpeech();
    final speech = SpeechPriorityCoordinator(engine);
    final owner = Object();
    Future<void> announce() => RideAcceptanceAnnouncement.announce(
        uid: 'p', requestId: 'ride', speech: speech, owner: owner, current: () => true);
    final lease = speech.claimPriority();
    await announce();
    expect(engine.messages, isEmpty);
    lease.release();
    await announce();
    expect(engine.messages, [RideAcceptanceAnnouncement.message]);
    speech.dispose();
  });

  test('invalidated account guard neither speaks nor marks the request announced', () async {
    final engine = RecordingSpeech();
    final speech = SpeechPriorityCoordinator(engine);
    var valid = false;
    Future<void> announce() => RideAcceptanceAnnouncement.announce(uid: 'p', requestId: 'ride',
        speech: speech, owner: engine, current: () => valid);
    await announce();
    expect(engine.messages, isEmpty);
    valid = true;
    await announce();
    expect(engine.messages, [RideAcceptanceAnnouncement.message]);
    speech.dispose();
  });
}
