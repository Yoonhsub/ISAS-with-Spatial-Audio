import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/models/v3_guidance_models.dart';
import 'package:mobi_passenger_app/src/features/voice_live/live_voice_page.dart';
import 'package:mobi_passenger_app/src/pages/home_page.dart';
import 'package:mobi_passenger_app/src/pages/ride_request_panel.dart';
import 'package:mobi_passenger_app/src/pages/v3_guidance_page.dart';
import 'package:mobi_passenger_app/src/services/backend_api_client.dart';
import 'package:mobi_passenger_app/src/services/local_guidance_runtime.dart';
import 'package:mobi_passenger_app/src/services/session_guidance_audio.dart';
import 'package:mobi_passenger_app/src/services/shared_guidance_session.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/src/services/ride_creation_intent.dart';

import 'guidance_reconnect_test.dart' show SilentSpeech;
import 'ride_business_flow_test.dart' show Session;

const plan = {
  'planId': 'plan711',
  'fallbackSource': 'PUBLIC_API',
  'segments': [
    {
      'routeId': 'CJB270009500',
      'routeNo': '711',
      'boardStop': {'stopId': 'CJB271000129'},
      'alightStop': {'stopId': 'other'}
    }
  ]
};

class RecordingSpeech extends SilentSpeech {
  final messages = <String>[];
  @override
  Future<void> speak(String text) async { messages.add(text); }
}

class RideFixture {
  RideFixture({this.routeNo = '711', this.transfer = false});
  final String routeNo;
  final bool transfer;
  Map<String, dynamic> get routePlan => {
    ...plan,
    'segments': [
      {...(plan['segments'] as List).first as Map<String, dynamic>, 'routeNo': routeNo},
      if (transfer) {'routeId': 'CJB_SECOND', 'routeNo': '502',
        'boardStop': {'stopId': 'other'}, 'alightStop': {'stopId': 'destination'}},
    ],
  };
  final auth = Session('owner');
  final shared = SharedGuidanceSession()..bind('owner');
  final commands = <String>[];
  final bodies = <Object?>[];
  final reads = <String>[];
  String decision = 'WAITING';
  String responseId = 'ride-711';
  String? recordOwner;
  String guidanceState = 'ROUTE_RECOMMENDED';
  Completer<void>? holdRead;
  Completer<void>? holdSelection;
  bool readingSelection = false;
  String returnedStop = 'CJB271000129';
  late final transport = MockClient(handle);
  late final authenticated = AuthenticatedApiClient(
      client: transport,
      tokenLoader: auth.getIdToken,
      requestGuard: () {
        final account = auth.currentAccount;
        return () => identical(account, auth.currentAccount);
      });
  late final api = BackendApiClient(
      baseUrl: 'http://127.0.0.1:8193',
      publicClient: transport,
      authClient: authenticated,
      useMockData: false);
  late final guidance = V3AgentApiClient(
      baseUrl: api.baseUrl,
      httpClient: transport,
      authClient: authenticated,
      visionLeaseEnabled: false);

  Future<http.Response> handle(http.Request request) async {
    if (request.url.host != '127.0.0.1') throw StateError('Unexpected test host');
    http.Response json(Object data) =>
        http.Response.bytes(utf8.encode(jsonEncode(data)), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
    final path = request.url.path;
    switch (path) {
      case '/health':
        return json({'status': 'ok'});
      case '/bus-info/stops/mock-stop-001/arrivals':
        return json({
          'arrivals': [
            {'routeId': 'home-502', 'busNo': '502'}
          ]
        });
      case '/guidance/session':
        return json({'sessionId': 's', 'state': 'IDLE'});
      case '/navigation/live-status':
        expect(request.url.queryParameters.keys,
            isNot(anyElement(isIn(['userLat', 'userLng', 'destLat', 'destLng']))));
        return json({
          'routeNo': routeNo,
          'walkingRouteToBoardStop': {
            'instructions': [{'description': '사거리에서 우회전하세요'}],
            'distanceMeters': 300,
            'durationSeconds': 240,
          },
          'arrivals': [{'routeNo': routeNo, 'arrivalMinutes': 5}],
          'fallbackSource': 'PUBLIC_API',
        });
      case '/agent/converse':
        final body = jsonDecode(request.body);
        if (body['sessionId'] != 's') throw StateError('Unexpected selection session');
        final text = body['utterance'] as String;
        commands.add(text);
        if (text == '이걸로 안내해줘' || text == '$routeNo번 버스 탈게') guidanceState = 'WAITING_FOR_BUS';
        return json({
          'sessionId': 's',
          'state': guidanceState,
          'intent': guidanceState == 'WAITING_FOR_BUS'
              ? 'SELECT_ARRIVAL'
              : 'FIND_ROUTE',
          'message': '$routeNo번 버스를 타세요. 타실 버스를 “몇 번 버스 탈게”라고 말씀해 주세요.',
          'ttsMode': 'NONE',
          if (guidanceState == 'ROUTE_RECOMMENDED')
            'routePlan': {'recommendedPlan': routePlan}
        });
      case '/guidance/state':
        if (request.url.queryParameters['sessionId'] != 's') throw StateError('Unexpected state session');
        readingSelection = true;
        await holdSelection?.future;
        return json({
          'sessionId': 's',
          'state': guidanceState,
          'selectedPlan': routePlan,
          if (guidanceState == 'WAITING_FOR_BUS') 'selectedRouteId': 'CJB270009500',
          'selectedRouteNo': routeNo,
          'selectedStopId': returnedStop
        });
      case '/ride-requests':
        if (request.method == 'GET') return json([]);
        expect(request.method, 'POST');
        expect(request.headers['authorization'], 'Bearer owner');
        bodies.add(jsonDecode(request.body));
        return json({'requestId': 'ride-711', 'status': 'WAITING'});
      case '/ride-requests/ride-711':
        expect(request.method, 'GET');
        reads.add(path);
        await holdRead?.future;
        return json({'requestId': responseId, 'status': decision,
          if (bodies.isNotEmpty) ...(bodies.last as Map<String, dynamic>),
          if (recordOwner != null) 'userId': recordOwner,
        });
      default:
        return http.Response('{}', 404);
    }
  }

  Widget home() => HomePage.testHarness(
      agentName: '모비',
      dataMode: 'mock',
      onEditAgentName: () {},
      onReturnToModeSelection: () {},
      api: api,
      auth: auth,
      rideSelection: shared.rideSelection);

  Future<V3GuidanceState?> select() => shared.rideSelection.confirm(
      client: guidance,
      sessionId: 's',
      uid: 'owner',
      wakeWord: '모비',
      mode: 'live',
      expected: V3RoutePlanCandidate.fromJson(routePlan),
      current: () => auth.currentAccount?.uid == 'owner');
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void audioChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in [
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
  ]) {
    messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }
  messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'), (_) async => 1);
  messenger.setMockMethodCallHandler(
      const MethodChannel('mobi.passenger/accepted-door'), (_) async => null);
  messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'), (call) async {
    if (call.method == 'create') {
      final id = (call.arguments as Map)['playerId'];
      messenger.setMockMethodCallHandler(
          MethodChannel('xyz.luan/audioplayers/events/$id'), (_) async => null);
    }
    return null;
  });
}

void main() {
  test('only the unique session bound to this passenger and active ride can resume', () async {
    SharedPreferences.setMockInitialValues({});
    final store = RideCreationIntentStore();
    await store.rememberRequest('p', 'current');
    await store.bindSession('p', 'session-a', 'current');
    expect(await store.sessionForActiveRequest('p', 'current'), 'session-a');
    expect(await store.sessionForActiveRequest('another-user', 'current'), isNull);
    expect(await store.sessionForActiveRequest('p', 'old'), isNull);
    await store.bindSession('p', 'session-b', 'current');
    expect(await store.sessionForActiveRequest('p', 'current'), isNull);
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final spokenConsent in [true, false]) {
    testWidgets('home 502 and ${spokenConsent ? "voice" : "button"} confirm server 711',
        (tester) async {
      audioChannels();
      tester.view.physicalSize = const Size(1080, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = RideFixture();
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: f.home()));
      await frames(tester);
      final send = find.widgetWithText(FilledButton, '탑승 요청하기');
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      expect(find.textContaining('502'), findsWidgets);
      final priority = SpeechPriorityCoordinator(SilentSpeech());
      final runtime = LocalGuidanceRuntime(
          client: f.guidance,
          rideApi: f.api,
          auth: f.auth,
          captureGuard: () => () => f.auth.currentAccount?.uid == 'owner',
          priority: priority,
          audio: SessionGuidanceAudio(priority: priority),
          controls: (_, __, ___) => const SizedBox());
      nav.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => V3GuidancePage(
              agentName: '모비',
              dataMode: 'live',
              onReturnToModeSelection: () {},
              sharedSession: f.shared,
              localRuntime: runtime)));
      await frames(tester);
      expect(find.text('채팅으로 질문하기'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      final open = find.text('음성으로 질문하기');
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pump(const Duration(milliseconds: 80));
      if (find.byType(LiveVoicePage).evaluate().isEmpty) await tester.tap(open);
      await frames(tester);
      final voice = tester.widget<LiveVoicePage>(find.byType(LiveVoicePage));
      await voice.processor('711번');
      await frames(tester);
      expect(f.shared.rideSelection.value, isNull);
      if (spokenConsent) {
        final result = await voice.processor('이 경로로 안내해줘');
        expect(result.navigateNow, isTrue);
        voice.onExit([], navigated: true);
        nav.currentState!.pop();
      } else {
        voice.onExit([], navigated: false);
        nav.currentState!.pop();
        await frames(tester);
        final start = find.text('이 경로로 안내 시작');
        await tester.ensureVisible(start);
        final startButton =
            find.ancestor(of: start, matching: find.byType(FilledButton));
        for (var i = 0;
            i < 30 &&
                tester.widget<FilledButton>(startButton).onPressed == null;
            i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(tester.widget<FilledButton>(startButton).onPressed, isNotNull);
        await tester.tapAt(tester.getCenter(start));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(tester.getCenter(start));
      }
      await frames(tester);
      expect(f.commands, ['711번', '이걸로 안내해줘']);
      expect(find.text('선택한 버스와 환승 정보'), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
      expect(find.textContaining('사거리에서 우회전하세요'), findsNothing);
      expect(find.textContaining('보행 경로'), findsNothing);
      nav.currentState!.pop();
      await frames(tester);
      expect(find.textContaining('502'), findsWidgets);
      await tester.ensureVisible(send);
      await tester.tap(send);
      await frames(tester);
      expect(f.bodies, [
        {
          'userId': 'owner',
          'routeId': 'CJB270009500',
          'busNo': '711',
          'stopId': 'CJB271000129'
        }
      ]);
      final decision = spokenConsent ? 'ACCEPTED' : 'REJECTED';
      f.responseId = 'other-request';
      f.decision = decision;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text(decision), findsNothing);
      f.responseId = 'ride-711';
      await tester.pump(const Duration(seconds: 5));
      await frames(tester);
      expect(find.text(decision), findsOneWidget);
      expect(find.text('요청 ID: ride-711'), spokenConsent ? findsOneWidget : findsNothing);
      expect(f.reads, List.filled(2, '/ride-requests/ride-711'));
      await tester.pump(const Duration(seconds: 5));
      await frames(tester);
      expect(f.reads, hasLength(spokenConsent ? 3 : 2));
      nav.currentState!.push(MaterialPageRoute<void>(builder: (_) =>
          V3GuidancePage(agentName: '모비', dataMode: 'live', visionOnly: true,
            onReturnToModeSelection: () {}, localRuntime: runtime, sharedSession: f.shared)));
      await frames(tester);
      expect(f.reads.last, '/ride-requests/ride-711');
      expect(find.text('안내 노선: 711번'), findsNothing);
      expect(find.text('수락된 버스: 711번'), spokenConsent ? findsOneWidget : findsNothing);
      expect(find.text('수락된 버스: 502번'), findsNothing);
      if (spokenConsent) {
        f.recordOwner = 'other-passenger';
        await tester.pump(const Duration(seconds: 5));
        await frames(tester);
        expect(find.text('수락된 버스: 711번'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });
  }

  for (final scenario in [('711', false), ('711-1', false), ('711', true)]) {
  final (number, transfer) = scenario;
  testWidgets('fixed voice $number transfer=$transfer confirmation creates a ride and camera waits for acceptance', (tester) async {
    audioChannels();
    final f = RideFixture(routeNo: number, transfer: transfer);
    final speech = RecordingSpeech();
    final priority = SpeechPriorityCoordinator(speech);
    final runtime = LocalGuidanceRuntime(
        client: f.guidance, rideApi: f.api, auth: f.auth,
        captureGuard: () => () => f.auth.currentAccount?.uid == 'owner',
        priority: priority, audio: SessionGuidanceAudio(priority: priority),
        controls: (_, __, ___) => const SizedBox());
    final nav = GlobalKey<NavigatorState>();
    Widget page(bool camera) => V3GuidancePage(agentName: '모비', dataMode: 'live',
      visionOnly: camera, localRuntime: runtime, sharedSession: f.shared,
      onReturnToModeSelection: () {});
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: page(false)));
    await frames(tester);
    final button = find.text('음성으로 질문하기');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 80));
    if (find.byType(LiveVoicePage).evaluate().isEmpty) {
      await tester.tap(button);
    }
    await frames(tester);
    final voice = tester.widget<LiveVoicePage>(find.byType(LiveVoicePage));
    // Inject final STT transcripts at the same callback used by the microphone.
    final guidance = await voice.processor('$number번');
    expect(guidance.spokenText, isNot(contains('타실 노선')));
    await voice.speak(guidance.spokenText);
    final spokenNumber = number.replaceAll('-', ' 다시 ');
    expect(speech.messages.last, contains('$spokenNumber번 버스를 타세요.'));
    final consent = await voice.processor('${number.replaceAll('-', ' 다시 ')}번 버스 탈게');
    expect(consent.spokenText, contains('탑승 요청을 보냈습니다'));
    expect(consent.navigateNow, isFalse);
    expect(f.bodies, hasLength(1));
    expect((f.bodies.single as Map)['busNo'], number);
    expect((f.bodies.single as Map)['routeId'], 'CJB270009500');
    expect((f.bodies.single as Map)['stopId'], 'CJB271000129');
    final duplicate = await voice.processor('${number.replaceAll('-', ' 다시 ')}번 버스 탈게');
    expect(duplicate.spokenText, contains('기존 탑승 요청'));
    expect(f.bodies, hasLength(1));
    voice.onExit([], navigated: consent.navigateNow);
    nav.currentState!.pop();
    await frames(tester);
    expect(f.commands, ['$number번', '$number번 버스 탈게']);
    expect(f.shared.rideSelection.value?.busNo, number);
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => page(true)));
    await frames(tester);
    expect(find.text('안내 노선: $number번'), findsNothing);
    expect(find.text('수락된 버스: $number번'), findsNothing);
    expect(f.bodies, hasLength(1));
    f.decision = 'ACCEPTED';
    await tester.pump(const Duration(seconds: 5));
    await frames(tester);
    expect(find.text('수락된 버스: $number번'), findsOneWidget);
    f.decision = 'CANCELLED';
    await tester.pump(const Duration(seconds: 5));
    await frames(tester);
    expect(find.text('수락된 버스: $number번'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  });

  }

  testWidgets('route panel shows a short status and tracks its hidden request ID',
      (tester) async {
    final fixture = RideFixture();
    await fixture.select();
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: RideRequestPanel.confirmed(
        api: fixture.api, session: fixture.auth,
        selection: fixture.shared.rideSelection, compact: true),
    )));
    await frames(tester);
    final send = find.widgetWithText(FilledButton, '탑승 요청하기');
    final refresh = find.widgetWithText(OutlinedButton, '상태 조회');
    final cancel = find.widgetWithText(OutlinedButton, '내 탑승 요청 취소');
    expect(tester.getSize(send).height, 48);
    expect(tester.getTopLeft(refresh).dy - tester.getBottomLeft(send).dy, 8);
    expect(tester.getTopLeft(cancel).dy - tester.getBottomLeft(refresh).dy, 8);
    await tester.tap(send);
    await frames(tester);
    expect(find.text('수락 대기'), findsOneWidget);
    expect(find.textContaining('ride-711'), findsNothing);
    expect(find.byKey(const ValueKey('ride-message')), findsNothing);
    fixture.decision = 'ACCEPTED';
    await tester.pump(const Duration(seconds: 5));
    await frames(tester);
    expect(find.text('수락됨'), findsOneWidget);
    expect(find.textContaining('ride-711'), findsNothing);
    expect(fixture.reads, ['/ride-requests/ride-711']);
    await tester.pumpWidget(const SizedBox());
  });

  test('a different boarding stop in the confirmation cannot authorize a ride',
      () async {
    final f = RideFixture()..returnedStop = 'old-502-stop';
    await expectLater(f.select(), throwsA(isA<V3ApiException>()));
    expect(f.shared.rideSelection.value, isNull);
    expect(f.bodies, isEmpty);
  });

  for (final nextUid in <String?>[null, 'other']) {
    testWidgets(
        'a late route confirmation cannot send after account change to $nextUid',
        (tester) async {
      final f = RideFixture()..holdSelection = Completer<void>();
      await tester.pumpWidget(MaterialApp(home: f.home()));
      final selection = f.select();
      await frames(tester);
      expect(f.readingSelection, isTrue);
      f.auth.switchTo(nextUid);
      f.shared.clear();
      f.holdSelection!.complete();
      expect(await selection, isNull);
      await frames(tester);
      final send = find.widgetWithText(FilledButton, '탑승 요청하기');
      await tester.ensureVisible(send);
      await tester.tap(send);
      await frames(tester);
      expect(f.bodies, isEmpty);
      expect(f.reads, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });
  }

  for (final logout in [true, false]) {
    testWidgets(
        'pending read cannot cross ${logout ? "logout" : "screen disposal"}',
        (tester) async {
      final f = RideFixture();
      await f.select();
      Widget panel(Key key) => MaterialApp(
          home: Scaffold(
              body: RideRequestPanel.confirmed(
                  key: key,
                  api: f.api,
                  session: f.auth,
                  selection: f.shared.rideSelection)));
      await tester.pumpWidget(panel(const ValueKey('first')));
      await frames(tester);
      await tester.tap(find.text('탑승 요청하기'));
      await frames(tester);
      f.holdRead = Completer();
      await tester.pump(const Duration(seconds: 5));
      expect(f.reads, hasLength(1));
      if (logout) {
        f.auth.switchTo(null);
        await frames(tester);
        expect(find.text('요청 ID: ride-711'), findsNothing);
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      f.auth.switchTo('other');
      await tester.pumpWidget(panel(const ValueKey('second')));
      await frames(tester);
      f.decision = 'ACCEPTED';
      f.holdRead!.complete();
      await frames(tester);
      expect(find.text('ACCEPTED'), findsNothing);
      expect(find.text('요청 ID: ride-711'), findsNothing);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, '탑승 요청하기'))
              .onPressed,
          isNull);
      await tester.pump(const Duration(seconds: 10));
      expect(f.reads, hasLength(1));
      expect(f.bodies, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });
  }
}
