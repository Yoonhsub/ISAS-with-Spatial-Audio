import 'package:flutter/foundation.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import '../models/v3_guidance_models.dart';
import 'backend_api_client.dart';
import 'ride_creation_intent.dart';
import 'v3_agent_api_client.dart';

/// A reserved, server-confirmed route used only by the joint debug trial.
class SavedRideTrial extends RideCreationIntentStore {
  static const enabled = bool.fromEnvironment('MOBI_ROUTE_DEMO');
  static const photoGuidance = bool.fromEnvironment('MOBI_ROUTE_PHOTO_DEMO', defaultValue: enabled);
  static const run = 'ride-20261122-r1';
  static const sessionId = 'rd-c8d3aef298d12b3e37882de3e1d320ec';
  static const identityRun = 'ride-20261115-a1';
  static const passenger = 'ct-$identityRun-passenger-a';
  static const backend =
      'https://ride-refresh-1122---mobi-api-u3sarfekmq-du.a.run.app';

  void checkConfiguration(String baseUrl) {
    if (!kDebugMode ||
        baseUrl != backend ||
        const String.fromEnvironment('MOBI_FIREBASE_PROJECT_ID') !=
            'mobi-auth-cloud-test' ||
        const String.fromEnvironment('MOBI_ROUTE_DEMO_RUN_ID') != run ||
        const String.fromEnvironment('MOBI_ROUTE_DEMO_RESUME_SESSION_ID') !=
            sessionId) {
      throw StateError('저장된 시험 경로의 실행 설정이 일치하지 않습니다.');
    }
  }

  Future<({V3GuidanceState state, RideRequestDraft draft})?> resume(
      V3AgentApiClient client,
      AuthSession auth,
      bool Function() current) async {
    final uid = auth.currentAccount?.uid;
    if (uid == null || uid != passenger) {
      throw StateError('이 502번 시험의 승객 계정으로 로그인해 주세요.');
    }
    if (!current()) return null;
    final role = await auth.getCustomClaim('mobi_role', forceRefresh: true);
    if (!current()) return null;
    final runClaim = await auth.getCustomClaim('mobi_cloud_test_run');
    if (!current()) return null;
    if (role != 'passenger' || runClaim != identityRun) {
      throw StateError('시험 승객 권한을 확인해 주세요.');
    }
    final state = await client.resumeSession(sessionId: sessionId);
    if (!current() || uid != auth.currentAccount?.uid) return null;
    final plan = state.selectedPlan;
    final segment = plan?.segments.singleOrNull;
    if (state.sessionId != sessionId ||
        state.state != 'WAITING_FOR_BUS' ||
        plan?.fallbackSource != 'MOCK' ||
        segment == null ||
        segment.source != 'LOCAL' ||
        segment.routeId != state.selectedRouteId ||
        segment.routeNo != state.selectedRouteNo ||
        segment.boardStop.stopId != state.selectedStopId ||
        segment.boardStop.order != 1 ||
        segment.alightStop.order != 2 ||
        segment.alightStop.stopId != 'mock-stop-001') {
      throw StateError('서버에 확정된 502번 시험 경로를 확인할 수 없습니다.');
    }
    final draft = RideRequestDraft(
        userId: uid,
        routeId: segment.routeId,
        busNo: segment.routeNo,
        stopId: segment.boardStop.stopId);
    _checkDraft(draft);
    return (state: state, draft: draft);
  }

  void _checkDraft(RideRequestDraft draft) {
    if (draft.userId != passenger ||
        draft.routeId != 'mock-route-502-west-east' ||
        draft.busNo != '502' ||
        draft.stopId != 'mock-stop-003' ||
        draft.targetDriverId != null) {
      throw StateError('시험 승객과 확정된 승차 경로가 일치하지 않습니다.');
    }
  }

  @override
  Future<String> begin(RideRequestDraft draft) async {
    _checkDraft(draft);
    return 'cloud-route-demo:$run:ride-01';
  }

  @override
  Future<void> complete(String uid, String key) async {
    // Every retry must use the single key reserved for this run.
  }

  @override
  Future<String?> activeRequest(String uid) async =>
      uid == passenger ? super.activeRequest('$run/$uid') : null;

  @override
  Future<void> rememberRequest(String uid, String requestId) =>
      super.rememberRequest('$run/$uid', requestId);
}
