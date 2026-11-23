import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/src/features/voice_live/live_voice_page.dart';
import 'package:mobi_passenger_app/src/pages/v3_guidance_page.dart';
import 'package:mobi_passenger_app/src/services/local_guidance_runtime.dart';
import 'package:mobi_passenger_app/src/services/ride_creation_intent.dart';
import 'package:mobi_passenger_app/src/services/session_guidance_audio.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';

import 'confirmed_passenger_ride_test.dart'
    show RideFixture, RecordingSpeech, audioChannels, frames;

class TransferFixture extends RideFixture {
  TransferFixture() : super(transfer: true);
  bool transferred = false, loseResponse = false;
  int transferCalls = 0, retries = 0;
  String secondStatus = 'WAITING';
  String? responseOwner;
  Completer<void>? holdTransfer;
  final transferStarted = Completer<void>();
  String get secondId => retries == 0 ? 'ride-502' : 'ride-502-retry-$retries';
  Map<String, dynamic> get secondPlan => {
        'planId': 'second',
        'type': 'DIRECT',
        'segments': [
          {
            'routeId': 'CJB_SECOND',
            'routeNo': '502',
            'boardStop': {'stopId': 'other'},
            'alightStop': {'stopId': 'destination'}
          }
        ],
      };
  Map<String, dynamic> get secondRecord => {
        'requestId': secondId,
        'status': secondStatus,
        'userId': responseOwner ?? 'owner',
        'routeId': 'CJB_SECOND',
        'busNo': '502',
        'stopId': 'other',
        'targetDriverId': 'driver',
      };
  Map<String, dynamic> get secondState => {
        'sessionId': 's',
        'state': 'WAITING_FOR_BUS',
        'selectedPlan': secondPlan,
        'selectedRouteId': 'CJB_SECOND',
        'selectedRouteNo': '502',
        'selectedStopId': 'other',
      };
  http.Response json(Object body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});

  @override
  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/ride-requests/ride-711/transfer') {
      expect(jsonDecode(request.body), {'sessionId': 's', 'busNo': '502'});
      expect(request.headers['authorization'], 'Bearer owner');
      transferCalls++;
      if (!transferStarted.isCompleted) transferStarted.complete();
      transferred = true;
      decision = 'COMPLETED';
      await holdTransfer?.future;
      if (loseResponse) {
        loseResponse = false;
        throw http.ClientException('response lost after committed transfer');
      }
      return json({
        'request': secondRecord,
        'guidanceState': secondState,
        'routePlan': {'recommendedPlan': secondPlan}
      });
    }
    if (transferred && path == '/guidance/state') return json(secondState);
    if (transferred && path == '/agent/converse') {
      final text = jsonDecode(request.body)['utterance'];
      if (text == '502번 버스 탈게') {
        commands.add(text);
        return json({
          'sessionId': 's',
          'state': 'WAITING_FOR_BUS',
          'intent': 'SELECT_ARRIVAL',
          'message': '502번 버스를 선택했습니다.',
          'ttsMode': 'NONE'
        });
      }
    }
    if (path.startsWith('/ride-requests/ride-502') && request.method == 'GET')
      return json(secondRecord);
    if (path == '/ride-requests' && request.method == 'POST') {
      expect(request.headers['x-guidance-session'], 's');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['busNo'] == '502') {
        expect(body, {
          'userId': 'owner',
          'routeId': 'CJB_SECOND',
          'busNo': '502',
          'stopId': 'other'
        });
        bodies.add(body);
        retries++;
        secondStatus = 'WAITING';
        return json(secondRecord);
      }
    }
    if (path == '/ride-requests' && request.method == 'GET' && transferred) {
      return json([
        secondRecord,
        {
          'requestId': 'ride-711',
          'status': 'COMPLETED',
          ...(bodies.first as Map<String, dynamic>)
        }
      ]);
    }
    return super.handle(request);
  }
}

class Harness {
  Harness(this.fixture) {
    runtime = createRuntime();
    cameraRuntime = createRuntime();
  }
  LocalGuidanceRuntime createRuntime() {
    final speech = RecordingSpeech();
    final priority = SpeechPriorityCoordinator(speech);
    return LocalGuidanceRuntime(
        client: fixture.guidance,
        rideApi: fixture.api,
        auth: fixture.auth,
        captureGuard: () => () => fixture.auth.currentAccount?.uid == 'owner',
        priority: priority,
        audio: SessionGuidanceAudio(priority: priority),
        controls: (_, __, ___) => const SizedBox());
  }

  final TransferFixture fixture;
  late final LocalGuidanceRuntime runtime;
  late final LocalGuidanceRuntime cameraRuntime;
  final nav = GlobalKey<NavigatorState>();
  Widget page(bool camera) => V3GuidancePage(
      agentName: '모비',
      dataMode: 'live',
      visionOnly: camera,
      localRuntime: camera ? cameraRuntime : runtime,
      sharedSession: fixture.shared,
      onReturnToModeSelection: () {});
  Future<LiveVoicePage> open(WidgetTester t) async {
    await t.pumpWidget(MaterialApp(navigatorKey: nav, home: page(false)));
    await frames(t);
    return enterVoice(t);
  }

  Future<LiveVoicePage> enterVoice(WidgetTester t) async {
    final button = find.text('음성으로 질문하기');
    await t.ensureVisible(button);
    await t.tap(button);
    await t.pump(const Duration(milliseconds: 80));
    if (find.byType(LiveVoicePage).evaluate().isEmpty) await t.tap(button);
    await frames(t);
    return t.widget<LiveVoicePage>(find.byType(LiveVoicePage));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    audioChannels();
  });

  for (final end in ['DENIED', 'CANCELLED']) {
    testWidgets(
        'voice requests second leg, gates camera and retries after $end',
        (t) async {
      final f = TransferFixture();
      // Each harness and transport share one authenticated owner.
      final harness = Harness(f);
      final voice = await harness.open(t);
      await voice.processor('711번');
      await voice.processor('711번 버스 탈게');
      expect((await voice.processor('502번 버스 탈게')).spokenText,
          contains('기존 탑승 요청'));
      expect(f.transferCalls, 0);
      f.decision = 'ACCEPTED';
      final result = await voice.processor('502번 버스 탈게');
      expect(result.spokenText, contains('502번 버스 탑승 요청을 보냈습니다'));
      expect(f.transferCalls, 1);
      expect(
          await RideCreationIntentStore().activeRequest('owner'), 'ride-502');
      expect(f.shared.rideSelection.value?.routeId, 'CJB_SECOND');
      expect(f.shared.rideSelection.value?.stopId, 'other');
      expect((await voice.processor('502번 버스 탈게')).spokenText,
          contains('기존 탑승 요청'));
      expect(f.transferCalls, 1);
      voice.onExit([], navigated: false);
      harness.nav.currentState!.pop();
      await frames(t);
      harness.nav.currentState!
          .push(MaterialPageRoute<void>(builder: (_) => harness.page(true)));
      await frames(t);
      expect(find.text('수락된 버스: 502번'), findsNothing);
      expect(find.text('수락된 버스: 711번'), findsNothing);
      f.secondStatus = 'ACCEPTED';
      await t.pump(const Duration(seconds: 5));
      await frames(t);
      expect(find.text('수락된 버스: 502번'), findsOneWidget);
      f.secondStatus = end;
      await t.pump(const Duration(seconds: 5));
      await frames(t);
      expect(find.text('수락된 버스: 502번'), findsNothing);
      harness.nav.currentState!.pop();
      await frames(t);
      // A terminal second request uses the same normal POST as a direct bus.
      final retryVoice = await harness.enterVoice(t);
      expect((await retryVoice.processor('502번 버스 탈게')).spokenText,
          contains('502번 버스 탑승 요청을 보냈습니다'));
      expect(f.retries, 1);
      expect(await RideCreationIntentStore().activeRequest('owner'),
          'ride-502-retry-1');
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 4));
    });
  }

  testWidgets(
      'lost transfer response retries durable parent without another ride',
      (t) async {
    final f = TransferFixture();
    final h = Harness(f);
    final voice = await h.open(t);
    await voice.processor('711번');
    await voice.processor('711번 버스 탈게');
    f.decision = 'ACCEPTED';
    f.loseResponse = true;
    expect((await voice.processor('502번 버스 탈게')).spokenText,
        contains('결과를 확인하지 못'));
    expect(
        (await RideCreationIntentStore()
            .pendingTransfer('owner'))?['requestId'],
        'ride-711');
    expect((await voice.processor('502번 버스 탈게')).spokenText,
        contains('502번 버스 탑승 요청을 보냈습니다'));
    expect(f.transferCalls, 2);
    expect(f.retries, 0);
    expect(await RideCreationIntentStore().activeRequest('owner'), 'ride-502');
    expect(await RideCreationIntentStore().pendingTransfer('owner'), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('late transfer response cannot activate a different account',
      (t) async {
    final f = TransferFixture();
    final h = Harness(f);
    final voice = await h.open(t);
    await voice.processor('711번');
    expect((await voice.processor('711번 버스 탈게')).spokenText,
        contains('요청을 보냈습니다'));
    await frames(t);
    f.decision = 'ACCEPTED';
    expect(
        (await f.api.fetchRideRequestStatus(requestId: 'ride-711')).statusLabel,
        'ACCEPTED');
    f.holdTransfer = Completer<void>();
    String? earlyMessage;
    final request = voice.processor('502번 버스 탈게').then((value) {
      earlyMessage = value.spokenText;
      return value;
    });
    await Future.any([f.transferStarted.future, request.then((_) {})]);
    expect(f.transferCalls, 1, reason: earlyMessage);
    f.auth.switchTo('other');
    f.holdTransfer!.complete();
    await request;
    expect(await RideCreationIntentStore().activeRequest('other'), isNull);
    expect(f.shared.rideSelection.value?.busNo, isNot('502'));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 4));
  });
}
