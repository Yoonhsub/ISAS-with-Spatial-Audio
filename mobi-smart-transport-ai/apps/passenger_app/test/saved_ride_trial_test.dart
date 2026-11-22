import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/services/backend_api_client.dart';
import 'package:mobi_passenger_app/src/services/saved_ride_trial.dart';
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ride_business_flow_test.dart' show Session;

class TrialLogin extends Session {
  TrialLogin() : super(SavedRideTrial.passenger);

  @override
  Future<String?> getCustomClaim(String name,
          {bool forceRefresh = false}) async =>
      name == 'mobi_role' ? 'passenger' : SavedRideTrial.identityRun;
}

void main() {
  for (final stop in ['mock-stop-003', 'other']) {
    test('stored 502 reads server state before creating a ride ($stop)',
        () async {
      final login = TrialLogin();
      final trial = SavedRideTrial();
      final requests = <String>[];
      final transport = MockClient((req) async {
        requests.add('${req.method} ${req.url.path}');
        expect(
            req.headers['authorization'], 'Bearer ${SavedRideTrial.passenger}');
        if (req.method == 'GET') {
          expect(
              req.url.queryParameters['sessionId'], SavedRideTrial.sessionId);
          return http.Response(
              jsonEncode({
                'sessionId': SavedRideTrial.sessionId,
                'state': 'WAITING_FOR_BUS',
                'selectedRouteId': 'mock-route-502-west-east',
                'selectedRouteNo': '502',
                'selectedStopId': stop,
                'selectedPlan': {
                  'fallbackSource': 'MOCK',
                  'segments': [
                    {
                      'source': 'LOCAL',
                      'routeId': 'mock-route-502-west-east',
                      'routeNo': '502',
                      'boardStop': {'order': 1, 'stopId': stop},
                      'alightStop': {'order': 2, 'stopId': 'mock-stop-001'}
                    }
                  ]
                }
              }),
              200);
        }
        expect(jsonDecode(req.body), {
          'userId': SavedRideTrial.passenger,
          'routeId': 'mock-route-502-west-east',
          'busNo': '502',
          'stopId': 'mock-stop-003'
        });
        expect(req.headers['Idempotency-Key'],
            'cloud-route-demo:ride-20261122-r1:ride-01');
        return http.Response(
            '{"requestId":"from-server","status":"WAITING"}', 200);
      });
      final authenticated = AuthenticatedApiClient(
          client: transport, tokenLoader: login.getIdToken);
      final guidance = V3AgentApiClient(
          baseUrl: 'http://127.0.0.1',
          authClient: authenticated,
          visionLeaseEnabled: false);
      if (stop == 'other') {
        await expectLater(
            trial.resume(guidance, login, () => true), throwsStateError);
        expect(requests, ['GET /guidance/state']);
        return;
      }
      final saved = (await trial.resume(guidance, login, () => true))!;
      expect(requests, ['GET /guidance/state']);
      final ride = BackendApiClient(
          baseUrl: guidance.baseUrl,
          authClient: authenticated,
          useMockData: false);
      final result = await ride.createRideRequest(
          draft: saved.draft, idempotencyKey: await trial.begin(saved.draft));
      expect(requests, ['GET /guidance/state', 'POST /ride-requests']);
      SharedPreferences.setMockInitialValues({});
      await trial.rememberRequest(SavedRideTrial.passenger, result.requestId!);
      expect(
          await trial.activeRequest(SavedRideTrial.passenger), 'from-server');
      expect(await trial.activeRequest('other'), isNull);
    });
  }
}
