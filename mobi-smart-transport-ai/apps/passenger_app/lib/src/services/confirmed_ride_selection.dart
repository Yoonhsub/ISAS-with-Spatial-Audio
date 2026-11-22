import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/v3_guidance_models.dart';
import 'backend_api_client.dart';
import 'v3_agent_api_client.dart';

/// Only a successful selection in the current guidance session can publish a draft.
class ConfirmedRideSelection extends ValueNotifier<RideRequestDraft?> {
  ConfirmedRideSelection() : super(null);

  int _revision = 0;
  V3GuidanceState? _confirmedState;
  String? get sessionId => _confirmedState?.sessionId;
  bool confirms(V3GuidanceState? state) =>
      state != null && identical(state, _confirmedState);
  Completer<void>? _revoked;
  Future<void>? get revoked => _revoked?.future;
  static bool isConfirmation(String text) =>
      RegExp(r'^[이그]경로로안내(?:해줘요?|해주세요|시작)[.!?]*$')
          .hasMatch(text.replaceAll(RegExp(r'\s+'), ''));

  void invalidate() {
    _confirmedState = null;
    _revoked?.complete();
    _revoked = null;
    _revision++;
    value = null;
  }

  void restore(RideRequestDraft draft) {
    invalidate();
    _revoked = Completer<void>();
    value = draft;
  }

  Future<V3GuidanceState?> confirm({
    required V3AgentApiClient client,
    required String sessionId,
    required String uid,
    required String wakeWord,
    required String mode,
    required V3RoutePlanCandidate expected,
    required bool Function() current,
  }) async {
    invalidate();
    final revision = _revision;
    bool active() => revision == _revision && current();
    if (!active() ||
        sessionId.isEmpty ||
        uid.isEmpty ||
        expected.segments.isEmpty) {
      return null;
    }
    late final V3GuidanceState state;
    try {
      final response = await client.converse(
          sessionId: sessionId,
          wakeWord: wakeWord,
          mode: mode,
          utterance: '이걸로 안내해줘');
      if (!active()) return null;
      if (response.sessionId != sessionId ||
          response.intent != 'SELECT_ARRIVAL' ||
          response.state != 'WAITING_FOR_BUS') {
        throw const V3ApiException('서버가 경로 선택을 확인하지 못했습니다.');
      }
      state = await client.fetchState(sessionId: sessionId);
      if (!active()) return null;
    } on V3ApiException {
      if (!active()) return null;
      rethrow;
    }
    final plan = state.selectedPlan;
    final segment = plan?.segments.firstOrNull;
    final shown = expected.segments.first;
    if (state.sessionId != sessionId ||
        state.state != 'WAITING_FOR_BUS' ||
        plan?.planId != expected.planId ||
        segment == null ||
        segment.routeId.trim().isEmpty ||
        segment.routeNo.trim().isEmpty ||
        segment.boardStop.stopId.trim().isEmpty ||
        segment.routeId != state.selectedRouteId ||
        segment.routeId != shown.routeId ||
        segment.routeNo != state.selectedRouteNo ||
        segment.routeNo != shown.routeNo ||
        segment.boardStop.stopId != state.selectedStopId ||
        segment.boardStop.stopId != shown.boardStop.stopId) {
      throw const V3ApiException('확정된 노선과 승차 정류장을 다시 확인해 주세요.');
    }
    _confirmedState = state;
    _revoked = Completer<void>();
    value = RideRequestDraft(
        userId: uid,
        routeId: segment.routeId,
        busNo: segment.routeNo,
        stopId: segment.boardStop.stopId);
    return state;
  }
}
