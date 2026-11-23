import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_driver_app/src/pages/home_page.dart';
import 'package:mobi_driver_app/src/services/backend_api_client.dart';

import 'auth_only_app_test.dart' show Session;

class Requests {
  final session = Session('driver');
  final statuses = <String, String>{};
  int reads = 0;
  int readStatus = 200;
  int updateStatus = 200;
  late final transport = MockClient((request) async {
    Object body = {};
    var status = 200;
    if (request.method == 'GET' &&
        request.url.path.endsWith('/ride-requests')) {
      reads++;
      status = readStatus;
      body = {
        'requests': statuses.entries
            .map((entry) => {
                  'requestId': entry.key,
                  'status': entry.value,
                  'busNo': '711',
                })
            .toList()
      };
    } else if (request.method == 'PATCH') {
      status = updateStatus;
      final id = request.url.pathSegments[1];
      if (status == 200) {
        statuses[id] = (jsonDecode(request.body) as Map)['status'] as String;
      } else if (status == 409) {
        statuses[id] = 'CANCELLED';
      }
      body = {'requestId': id, 'status': statuses[id]};
    }
    return http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });
  late final client = BackendApiClient(
    baseUrl: 'http://127.0.0.1:8123',
    useMockData: false,
    publicClient: transport,
    authClient: AuthenticatedApiClient(
        client: transport,
        tokenLoader: ({bool forceRefresh = false}) async => 'local-test',
        requestGuard: () => () => true),
  );

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        MaterialApp(home: HomePage(apiClient: client, session: session)));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await session.events.close();
    transport.close();
  }
}

Future<void> tap(WidgetTester tester, String label) async {
  final button = find.text(label).first;
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> wait(WidgetTester tester, int seconds) async {
  await tester.pump(Duration(seconds: seconds));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'failed manual refresh does not restart polling for a received request',
      (tester) async {
    final requests = Requests()..statuses['ride-1'] = 'WAITING';
    await requests.open(tester);
    requests.readStatus = 500;
    await tap(tester, '요청 목록 새로고침');
    expect(requests.reads, 2);
    await wait(tester, 180);
    expect(requests.reads, 2);
    requests.readStatus = 200;
    requests.statuses['ride-1'] = 'CANCELLED';
    await tap(tester, '요청 목록 새로고침');
    expect(requests.reads, 3);
    await wait(tester, 60);
    expect(requests.reads, 4);
    await requests.close(tester);
  });
  testWidgets(
      'receiving and accepting a request pauses polling; cancellation resumes it',
      (tester) async {
    final requests = Requests();
    await requests.open(tester);
    expect(requests.reads, 1);
    expect(find.text('진행 중인 요청이 없을 때 새 요청을 1분마다 확인합니다.'), findsOneWidget);
    requests.statuses['ride-1'] = 'WAITING';
    await wait(tester, 59);
    expect(requests.reads, 1);
    await wait(tester, 1);
    expect(requests.reads, 2);
    await wait(tester, 240);
    expect(requests.reads, 2);
    expect(find.text('요청 수락'), findsOneWidget);
    await tap(tester, '요청 목록 새로고침');
    expect(requests.reads, 3);
    await wait(tester, 120);
    expect(requests.reads, 3);
    await tap(tester, '요청 수락');
    expect(requests.statuses['ride-1'], 'ACCEPTED');
    expect(requests.reads, 4);
    await wait(tester, 180);
    expect(requests.reads, 4);
    await tap(tester, '승인한 요청 취소');
    expect(requests.reads, 5);
    expect(requests.statuses['ride-1'], 'CANCELLED');
    await wait(tester, 60);
    expect(requests.reads, 6);
    requests.statuses['ride-2'] = 'WAITING';
    await wait(tester, 60);
    expect(requests.reads, 7);
    await wait(tester, 180);
    expect(requests.reads, 7);
    await requests.close(tester);
  });

  testWidgets(
      'history does not resume polling while another active request remains',
      (tester) async {
    final requests = Requests()
      ..statuses.addAll({'ride-1': 'WAITING', 'ride-2': 'NOTIFIED'});
    await requests.open(tester);
    await tap(tester, '요청 거부');
    expect(requests.reads, 2);
    await tap(tester, '이전 요청 기록');
    await wait(tester, 180);
    expect(requests.reads, 2);
    await tap(tester, '이전 요청 기록');
    await tap(tester, '요청 거부');
    expect(requests.reads, 3);
    expect(requests.statuses.values, everyElement('DENIED'));
    await wait(tester, 60);
    expect(requests.reads, 4);
    await requests.close(tester);
  });

  testWidgets(
      'failed approval stays paused and conflicting status is reloaded once',
      (tester) async {
    final requests = Requests()..statuses['ride-1'] = 'WAITING';
    await requests.open(tester);
    requests.updateStatus = 500;
    await tap(tester, '요청 수락');
    await wait(tester, 180);
    expect(requests.reads, 1);
    expect(requests.statuses['ride-1'], 'WAITING');
    requests.updateStatus = 409;
    await tap(tester, '요청 수락');
    expect(requests.reads, 2);
    expect(requests.statuses['ride-1'], 'CANCELLED');
    await wait(tester, 60);
    expect(requests.reads, 3);
    await requests.close(tester);
  });
}
