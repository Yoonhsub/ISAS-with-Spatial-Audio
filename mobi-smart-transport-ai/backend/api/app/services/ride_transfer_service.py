"""One confirmed next bus, with atomic completion and durable retry identity."""
import hashlib
from typing import Any

from fastapi import HTTPException

from app.schemas.ride_request import RideRequestCreate, RideRequestStatus as Status
from app.schemas.v3 import (GuidanceState, RoutePlanCandidate, RoutePlanResponse,
                            RoutePlanType, FallbackSource)
from app.security import require_role, auth_error, valid_key
from app.services.ride_request_service import RideRequestService
from app.services.v3_guidance_store import v3_guidance_store


def conflict(code, message):
    return HTTPException(409, {'code': code, 'message': message})


class RideTransferService:
    def __init__(self, rides: RideRequestService):
        self.rides = rides
        self.db = rides.firebase

    def journey_for_creation(self, session_id, payload):
        session = v3_guidance_store.get(session_id)
        if session.state != GuidanceState.WAITING_FOR_BUS or not session.selected_plan or not session.last_route_plan:
            raise conflict('ROUTE_NOT_CONFIRMED', '먼저 안내받은 버스를 확정해 주세요.')
        plan = RoutePlanCandidate.model_validate(session.selected_plan)
        first = plan.segments[0] if plan.segments else None
        if first is None or (first.routeId, first.routeNo, first.boardStop.stopId) != (
                payload.routeId, payload.busNo, payload.stopId):
            raise conflict('ROUTE_MISMATCH', '확정한 노선과 승차 정류장이 다릅니다.')
        route = RoutePlanResponse.model_validate(session.last_route_plan)
        return {'plan': plan.model_dump(mode='json'), 'legIndex': 0,
                'destination': route.destination.model_dump(mode='json'), 'heardText': route.heardText}

    def bind(self, request_id, journey):
        principal = require_role('passenger')
        def update(raw):
            self.rides._authorized_record(request_id, raw, principal)
            if raw.get('_journey') is not None:
                if raw['_journey'] != journey:
                    raise conflict('JOURNEY_MISMATCH', '기존 요청에 연결된 경로와 다릅니다.')
                return raw
            return {**raw, '_journey': journey}
        self.db.transaction(self.rides._record_path(request_id), update)

    def transfer(self, request_id: str, bus_no: str, session_id: str):
        principal = require_role('passenger')
        # Check session ownership before changing persistent requests.
        session = v3_guidance_store.get(session_id)
        if not valid_key(request_id):
            raise auth_error(403, 'Invalid resource identifier')
        raw = self.db.get(self.rides._record_path(request_id))
        previous = self.rides._authorized_record(request_id, raw, principal)
        journey = raw.get('_journey')
        if journey is None:
            # Compatibility for a first-leg request made by the previous APK.
            try:
                journey = self.journey_for_creation(session_id, RideRequestCreate(
                    userId=previous.userId, routeId=previous.routeId, busNo=previous.busNo, stopId=previous.stopId))
            except HTTPException:
                raise conflict('NO_TRANSFER', '연결된 환승 경로가 없습니다. 현재 위치에서 경로를 다시 검색해 주세요.') from None
        plan = RoutePlanCandidate.model_validate(journey['plan'])
        index = journey['legIndex']
        if not isinstance(index, int) or not 0 <= index < len(plan.segments) - 1:
            raise conflict('NO_TRANSFER', '이 요청에는 다음 환승 버스가 없습니다.')
        current, following = plan.segments[index:index + 2]
        if (current.routeId, current.routeNo, current.boardStop.stopId) != (previous.routeId, previous.busNo, previous.stopId):
            raise conflict('JOURNEY_MISMATCH', '현재 요청과 환승 경로를 다시 확인해 주세요.')
        if bus_no != following.routeNo:
            raise conflict('WRONG_TRANSFER_BUS', f'다음에 탈 {following.routeNo}번 버스 번호를 말씀해 주세요.')
        if current.alightStop.stopId != following.boardStop.stopId:
            raise conflict('TRANSFER_STOP_MISMATCH', '같은 정류장에서 갈아타는 경로만 요청할 수 있습니다.')
        payload = RideRequestCreate(userId=previous.userId, routeId=following.routeId,
                                    busNo=following.routeNo, stopId=following.boardStop.stopId)
        key = 'transfer.' + hashlib.sha256(request_id.encode()).hexdigest()
        next_id, fingerprint = self.rides._creation_identity(principal.uid, key, payload)
        next_journey = {**journey, 'legIndex': index + 1}
        existing = self.db.get(self.rides._record_path(next_id))
        candidate = None
        if existing is None:
            if previous.status not in {Status.ACCEPTED, Status.ARRIVED, Status.COMPLETED}:
                raise conflict('FIRST_RIDE_NOT_ACCEPTED', '첫 번째 탑승 요청이 승인된 뒤 환승 요청을 보낼 수 있습니다.')
            assigned = self.rides._resolve_assignment(payload, principal)
            candidate = {**assigned.model_dump(mode='json'), 'status': Status.WAITING.value,
                'createdAt': self.rides._serialize_datetime(self.rides._next_created_at()), 'updatedAt': None,
                '_journey': next_journey,
                '_creation': {'version': 1, 'uid': principal.uid, 'fingerprint': fingerprint,
                    'notification': {'state': 'pending' if assigned.targetDriverId else 'not_required'}}}

        def transition(records: Any):
            records = records if isinstance(records, dict) else {}
            old = records.get(request_id)
            state = self.rides._authorized_record(request_id, old, principal)
            if (state.routeId, state.busNo, state.stopId) != (previous.routeId, previous.busNo, previous.stopId):
                raise conflict('JOURNEY_MISMATCH', '현재 요청의 노선이나 승차 정류장이 변경되었습니다.')
            if old.get('_journey', journey) != journey:
                raise conflict('JOURNEY_MISMATCH', '환승 경로가 변경되었습니다.')
            if old.get('_transfer') == next_id:
                self.rides._check_creation(next_id, records.get(next_id), principal, fingerprint)
                return records
            if state.status not in {Status.ACCEPTED, Status.ARRIVED, Status.COMPLETED}:
                raise conflict('FIRST_RIDE_NOT_ACCEPTED', '첫 번째 요청이 취소되었거나 아직 승인되지 않았습니다.')
            if old.get('_transfer') is not None or records.get(next_id) is not None or candidate is None:
                raise conflict('TRANSFER_CONFLICT', '이미 처리된 환승 요청을 확인해 주세요.')
            # One RTDB transaction: no gap with two active rides, or a completed
            # first ride with a missing next request. Unrelated records survive.
            return {**records, request_id: {**old, 'status': Status.COMPLETED.value,
                'updatedAt': self.rides._next_updated_at(state), '_journey': journey, '_transfer': next_id},
                next_id: candidate}

        self.db.transaction(self.rides.ROOT_PATH, transition)
        self.rides._notify_idempotent(next_id, principal, fingerprint)
        remaining = self.remaining_plan(next_journey)
        # The durable request remains authoritative if an HTTP response is lost.
        # Retrying the same parent reuses next_id and reconstructs this state.
        from app.api.routes.v3_agent import _apply_route_plan
        _apply_route_plan(session, remaining)
        session.state = GuidanceState.WAITING_FOR_BUS
        session.touch()
        return {'request': self.rides.get(next_id), 'guidanceState': session.to_response(), 'routePlan': remaining}

    @staticmethod
    def remaining_plan(journey):
        plan = RoutePlanCandidate.model_validate(journey['plan'])
        index = journey['legIndex']
        segments = [segment.model_copy(update={'arrivals': [], 'arrivalUnknown': True,
            'arrivalSource': FallbackSource.ERROR, 'estimatedMinutes': None, 'serviceStatus': None})
            for segment in plan.segments[index:]]
        first = segments[0]
        remaining = plan.model_copy(update={'planId': f'{plan.planId}-leg-{index}',
            'type': RoutePlanType.DIRECT if len(segments) == 1 else RoutePlanType.ONE_TRANSFER,
            'segments': segments, 'legs': [], 'transferCount': len(segments) - 1,
            'totalBusStopCount': sum(s.stopCount for s in segments), 'totalEstimatedMinutes': None,
            'arrival': None, 'serviceStatus': None,
            'summary': f'{first.routeNo}번 버스로 이어서 이동합니다.',
            'boardingInstruction': f'{first.boardStop.stopName} 정류장에서 {first.routeNo}번 버스를 타세요.'})
        return RoutePlanResponse(status='RESOLVED', readiness='READY', heardText=journey['heardText'],
            destination=journey['destination'], plans=[remaining], recommendedPlan=remaining,
            agentMessage=remaining.boardingInstruction, fallbackSource=remaining.fallbackSource)
