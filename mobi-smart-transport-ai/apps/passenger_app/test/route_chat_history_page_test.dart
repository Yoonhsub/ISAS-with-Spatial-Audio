import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/pages/v3_guidance_page.dart';
import 'package:mobi_passenger_app/src/services/backend_api_client.dart';
import 'package:mobi_passenger_app/src/services/shared_guidance_session.dart';
import 'package:mobi_passenger_app/src/services/local_guidance_runtime.dart';
import 'package:mobi_passenger_app/src/services/session_guidance_audio.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';
import 'package:mobi_passenger_app/src/widgets/chat_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'guidance_reconnect_test.dart' show DemoAuth, SilentSpeech;

void main() {
  testWidgets(
      'failed live chat restart keeps the draft; retry starts clean and saves history',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (_) async => null);
    }
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

    final requestLog = <String>[];
    final unexpectedRequests = <String>[];
    Iterable<String> chatTraffic() =>
        requestLog.where((request) => request != 'GET /guidance/safety-events');
    final sessionIds = <String>[];
    final chatSessionIds = <String>[];
    final safetySessionIds = <String>[];
    final sessionsWithTurns = <String>{};
    var failNextCreate = false;
    final transport = MockClient((request) async {
      final path = request.url.path;
      requestLog.add('${request.method} $path');
      expect(request.url.host, '127.0.0.1');
      Map<String, Object?> state(String id) => {
            'sessionId': id,
            'state': 'IDLE',
            if (sessionsWithTurns.contains(id)) 'selectedRouteNo': '711',
          };
      http.Response reply(Map<String, Object?> body) =>
          http.Response(jsonEncode(body), 200,
              headers: {'content-type': 'application/json'});

      switch ((request.method, path)) {
        case ('GET', '/health'):
          return reply({});
        case ('POST', '/guidance/session'):
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body, {'wakeWord': 'mobi'});
          if (failNextCreate) {
            failNextCreate = false;
            return http.Response(
                '{"detail":"Test session temporarily unavailable"}', 503,
                headers: {'content-type': 'application/json'});
          }
          final id = 'local-session-${sessionIds.length + 1}';
          sessionIds.add(id);
          return reply(state(id));
        case ('POST', '/agent/converse'):
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final sid = body['sessionId'] as String;
          expect(sid, isIn(sessionIds));
          expect(body['mode'], 'live');
          chatSessionIds.add(sid);
          sessionsWithTurns.add(sid);
          return reply({
            'sessionId': sid,
            'message': '모의 응답: ${body['utterance']}',
            'ttsMode': 'NONE',
          });
        case ('GET', '/guidance/state'):
          final sid = request.url.queryParameters['sessionId']!;
          expect(sid, isIn(sessionIds));
          return reply(state(sid));
        case ('GET', '/guidance/safety-events'):
          final sid = request.url.queryParameters['sessionId']!;
          expect(sid, isIn(sessionIds));
          safetySessionIds.add(sid);
          return reply({
            'sessionId': sid,
            'ownerUid': 'owner',
            'generation': 'test-safety-$sid',
            'cursor': 0,
            'events': [],
          });
        default:
          unexpectedRequests.add('${request.method} $path');
          return http.Response('{"detail":"Unexpected test request"}', 404);
      }
    });

    final client = V3AgentApiClient(
        baseUrl: 'http://127.0.0.1:18459',
        httpClient: transport,
        visionLeaseEnabled: false,
        authClient: AuthenticatedApiClient(
            tokenLoader: ({bool forceRefresh = false}) async => 'local-test',
            requestGuard: () => () => true,
            client: transport));
    final priority = SpeechPriorityCoordinator(SilentSpeech());
    final runtime = LocalGuidanceRuntime(
        client: client,
        auth: DemoAuth(),
        captureGuard: () => () => true,
        priority: priority,
        audio: SessionGuidanceAudio(priority: priority),
        controls: (_, __, ___) => const SizedBox());
    addTearDown(priority.dispose);

    final overlay = find.byType(ChatOverlay);
    Finder inChat(Finder finder) =>
        find.descendant(of: overlay, matching: finder);
    final composer = inChat(find.byType(TextField));

    late SharedGuidanceSession shared;
    Future<void> openPage() async {
      shared = SharedGuidanceSession();
      await tester.pumpWidget(MaterialApp(
          home: V3GuidancePage(
              agentName: 'mobi',
              onReturnToModeSelection: () {},
              dataMode: 'live',
              sharedSession: shared,
              localRuntime: runtime)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('채팅으로 질문하기'));
      final chatButton = tester.getCenter(find.text('채팅으로 질문하기'));
      // DescribedAction consumes the first raw tap for its audio description.
      await tester.tapAt(chatButton);
      await tester.pump();
      await tester.tapAt(chatButton);
      await tester.pumpAndSettle();
    }

    Future<void> send(String message) async {
      await tester.enterText(composer, message);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(inChat(find.text('모의 응답: $message')), findsOneWidget);
    }

    Future<void> tapChat(String text) async {
      await tester.tap(inChat(find.text(text)));
      await tester.pumpAndSettle();
    }

    await openPage();
    expect(sessionIds, ['local-session-1']);
    await send('첫 시험 질문');
    expect(chatSessionIds, ['local-session-1']);
    expect(find.text('노선: 711'), findsOneWidget);

    const previousRide = RideRequestDraft(userId: 'owner',
        routeId: 'CJB270009500', busNo: '711', stopId: 'CJB271000129');
    shared.rideSelection.restore(previousRide);
    const pendingDraft = '전송하지 않은 시험 질문';
    await tester.enterText(composer, pendingDraft);
    final beforeFailedRestart = chatTraffic().length;
    failNextCreate = true;
    await tapChat('새 대화');
    expect(chatTraffic().skip(beforeFailedRestart), ['POST /guidance/session']);
    expect(sessionIds, ['local-session-1']);
    expect(chatSessionIds, ['local-session-1']);
    expect(inChat(find.text('새 대화를 열지 못했습니다. 다시 시도해 주세요.')), findsOneWidget);
    expect(shared.rideSelection.value, same(previousRide));
    expect(tester.widget<ChatOverlay>(overlay).activeChatId, 'local-session-1');
    expect(tester.widget<TextField>(composer).controller!.text, pendingDraft);
    expect(inChat(find.text('첫 시험 질문')), findsOneWidget);
    expect(inChat(find.text('모의 응답: 첫 시험 질문')), findsOneWidget);
    expect(find.text('노선: 711'), findsOneWidget);

    await tapChat('새 대화');
    expect(chatTraffic().skip(beforeFailedRestart),
        ['POST /guidance/session', 'POST /guidance/session']);
    expect(sessionIds, ['local-session-1', 'local-session-2']);
    expect(shared.state?.sessionId, 'local-session-2');
    expect(shared.rideSelection.value, isNull);
    expect(tester.widget<ChatOverlay>(overlay).activeChatId, 'local-session-2');
    expect(inChat(find.text('새 대화를 열지 못했습니다. 다시 시도해 주세요.')), findsNothing);
    expect(composer, findsOneWidget);
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
    expect(inChat(find.text('첫 시험 질문')), findsNothing);
    expect(inChat(find.text('모의 응답: 첫 시험 질문')), findsNothing);
    expect(find.text('노선: 711'), findsNothing);
    await send('둘째 시험 질문');
    expect(chatSessionIds, ['local-session-1', 'local-session-2']);

    final beforeArchive = chatTraffic().toList();
    final safetyBeforeArchive = safetySessionIds.length;
    await tapChat('최근 대화');
    expect(inChat(find.text('1. 둘째 시험 질문')), findsOneWidget);
    await tapChat('2. 첫 시험 질문');
    expect(inChat(find.text('이전 대화 · 읽기 전용')), findsOneWidget);
    expect(shared.rideSelection.value, isNull);
    expect(inChat(find.text('첫 시험 질문')), findsOneWidget);
    expect(inChat(find.text('모의 응답: 첫 시험 질문')), findsOneWidget);
    expect(inChat(find.text('둘째 시험 질문')), findsNothing);
    expect(composer, findsNothing);
    await tapChat('현재 대화로 돌아가기');
    expect(inChat(find.text('둘째 시험 질문')), findsOneWidget);
    expect(composer, findsOneWidget);
    expect(chatTraffic(), beforeArchive);
    expect(safetySessionIds.skip(safetyBeforeArchive),
        everyElement('local-session-2'));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await openPage();
    expect(
        sessionIds, ['local-session-1', 'local-session-2', 'local-session-3']);
    expect(inChat(find.text('둘째 시험 질문')), findsNothing);
    final afterReopen = chatTraffic().toList();
    final safetyAfterReopen = safetySessionIds.length;
    await tapChat('최근 대화');
    final second = inChat(find.text('1. 둘째 시험 질문'));
    final first = inChat(find.text('2. 첫 시험 질문'));
    expect(second, findsOneWidget);
    expect(first, findsOneWidget);
    expect(tester.getTopLeft(second).dy, lessThan(tester.getTopLeft(first).dy));
    await tapChat('2. 첫 시험 질문');
    expect(inChat(find.text('이전 대화 · 읽기 전용')), findsOneWidget);
    expect(composer, findsNothing);
    expect(chatTraffic(), afterReopen);
    expect(safetySessionIds.skip(safetyAfterReopen),
        everyElement('local-session-3'));
    expect(unexpectedRequests, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
