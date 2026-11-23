from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from app.main import app

from app.api.routes.v3_agent import _apply_route_plan
from app.schemas.ride_request import RideRequestCreate, RideRequestStatus as S
from app.schemas.v3 import GuidanceState
from app.security import Principal, current_principal, get_principal
from app.services.firebase_client import get_firebase_client
from app.services.ride_request_service import RideRequestService
from app.services.ride_transfer_service import RideTransferService
from app.services.v3_guidance_store import v3_guidance_store
from test_live_transfer_planning import Fixture as Routes


@contextmanager
def as_user(uid='passenger', role='passenger', driver=None):
    token = current_principal.set(Principal(uid, role, driver))
    try:
        yield
    finally:
        current_principal.reset(token)


@pytest.fixture
def ride(monkeypatch):
    routes = Routes(monkeypatch)
    db = get_firebase_client()
    db.clear_mock_store()
    db.set('/drivers/demo-driver', {'active': True, 'acceptsSelectedRoutes': True})
    service = RideRequestService(db, SimpleNamespace(send_ride_request_notification=lambda **_: SimpleNamespace(accepted=False)))
    transfers = RideTransferService(service)
    with as_user():
        session = v3_guidance_store.create(wake_word='모비')
        _apply_route_plan(session, routes.plan())
        session.state = GuidanceState.WAITING_FOR_BUS
        draft = RideRequestCreate(userId='passenger', routeId='CJB_A', busNo='11', stopId='CJB_ORIGIN')
        first = service.create(draft, 'first-request-key-0001',
            journey=transfers.journey_for_creation(session.session_id, draft))
    fixture = SimpleNamespace(db=db, service=service, transfers=transfers, session=session, first=first, draft=draft)
    yield fixture
    db.clear_mock_store()


def decide(ride, request_id, status):
    with as_user('driver', 'driver', 'demo-driver'):
        return ride.service.update_status(request_id, status)


def transfer(ride, *, number='22', session_id=None):
    with as_user():
        return ride.transfers.transfer(ride.first.requestId, number, session_id or ride.session.session_id)


def test_transfer_completes_first_and_dispatches_second_at_transfer_stop(ride):
    decide(ride, ride.first.requestId, S.ACCEPTED)
    result = transfer(ride)
    second = result['request']
    assert (second.busNo, second.routeId, second.stopId, second.status) == ('22', 'CJB_B', 'CJB_TRANSFER', S.WAITING)
    assert second.targetDriverId == 'demo-driver'
    with as_user():
        assert ride.service.get(ride.first.requestId).status == S.COMPLETED
        assert len(ride.service.list_for_passenger()) == 2
    assert result['guidanceState'].selectedRouteNo == '22'
    assert result['guidanceState'].selectedStopId == 'CJB_TRANSFER'
    assert len(result['guidanceState'].selectedPlan['segments']) == 1
    assert result['routePlan'].recommendedPlan.transferCount == 0
    assert result['routePlan'].recommendedPlan.segments[0].arrivals == []
    decide(ride, second.requestId, S.ACCEPTED)
    decide(ride, second.requestId, S.CANCELLED)
    with as_user():
        assert {r.status for r in ride.service.list_for_passenger()} == {S.COMPLETED, S.CANCELLED}


@pytest.mark.parametrize('status', [S.WAITING, S.DENIED, S.CANCELLED])
def test_unapproved_first_ride_cannot_advance(ride, status):
    if status != S.WAITING:
        decide(ride, ride.first.requestId, status)
    with pytest.raises(HTTPException) as error:
        transfer(ride)
    assert error.value.status_code == 409
    assert len(ride.db.get('/rideRequests')) == 1


def test_unoffered_bus_does_not_complete_first_request(ride):
    decide(ride, ride.first.requestId, S.ACCEPTED)
    with pytest.raises(HTTPException):
        transfer(ride, number='999')
    assert ride.db.get('/rideRequests/' + ride.first.requestId)['status'] == 'ACCEPTED'


@pytest.mark.parametrize('uid,role,driver', [('other', 'passenger', None), ('driver', 'driver', 'demo-driver')])
def test_other_passenger_or_driver_cannot_trigger_transfer(ride, uid, role, driver):
    decide(ride, ride.first.requestId, S.ACCEPTED)
    with as_user(uid, role, driver), pytest.raises(HTTPException) as error:
        ride.transfers.transfer(ride.first.requestId, '22', ride.session.session_id)
    assert error.value.status_code == 403
    assert len(ride.db.get('/rideRequests')) == 1


def test_missing_second_driver_keeps_first_request_accepted(ride):
    decide(ride, ride.first.requestId, S.ACCEPTED)
    ride.db.set('/drivers/demo-driver', {'active': False})
    with pytest.raises(HTTPException):
        transfer(ride)
    assert ride.db.get('/rideRequests/' + ride.first.requestId)['status'] == 'ACCEPTED'
    assert len(ride.db.get('/rideRequests')) == 1


def test_repeated_or_concurrent_transfer_has_one_successor(ride):
    decide(ride, ride.first.requestId, S.ACCEPTED)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: transfer(ride), range(2)))
    assert results[0]['request'].requestId == results[1]['request'].requestId
    assert transfer(ride)['request'].requestId == results[0]['request'].requestId
    assert len(ride.db.get('/rideRequests')) == 2


def test_cancellation_race_is_rechecked_inside_atomic_transition(ride, monkeypatch):
    decide(ride, ride.first.requestId, S.ACCEPTED)
    transaction = ride.db.transaction
    def racing(path, update):
        if path == '/rideRequests':
            def cancelled(records):
                records[ride.first.requestId]['status'] = 'CANCELLED'
                return update(records)
            return transaction(path, cancelled)
        return transaction(path, update)
    monkeypatch.setattr(ride.db, 'transaction', racing)
    with pytest.raises(HTTPException):
        transfer(ride)
    assert len(ride.db.get('/rideRequests')) == 1


def test_persisted_itinerary_supports_new_session_and_new_service_instance(ride):
    decide(ride, ride.first.requestId, S.ACCEPTED)
    with as_user():
        fresh = v3_guidance_store.create(wake_word='모비')
        instance = RideTransferService(RideRequestService(ride.db, ride.service.fcm))
        result = instance.transfer(ride.first.requestId, '22', fresh.session_id)
    assert result['guidanceState'].sessionId == fresh.session_id
    assert result['request'].busNo == '22'


def test_previous_apk_request_can_bind_verified_session_for_transfer(ride):
    decide(ride, ride.first.requestId, S.ACCEPTED)
    path = '/rideRequests/' + ride.first.requestId
    raw = ride.db.get(path)
    raw.pop('_journey')
    ride.db.set(path, raw)
    assert transfer(ride)['request'].busNo == '22'


def test_denied_second_ride_can_retry_through_normal_creation(ride):
    decide(ride, ride.first.requestId, S.ACCEPTED)
    second = transfer(ride)['request']
    decide(ride, second.requestId, S.DENIED)
    with as_user():
        # Same regular creation path and first segment of the remaining plan.
        draft = RideRequestCreate(userId='passenger', routeId='CJB_B', busNo='22', stopId='CJB_TRANSFER')
        journey = ride.transfers.journey_for_creation(ride.session.session_id, draft)
        retry = ride.service.create(draft, 'retry-second-request-0001')
        ride.transfers.bind(retry.requestId, journey)
    assert retry.requestId != second.requestId
    assert retry.status == S.WAITING
    with as_user():
        assert {r.status for r in ride.service.list_for_passenger()} == {S.COMPLETED, S.DENIED, S.WAITING}


def test_http_creation_binds_itinerary_and_transfer_returns_public_contract(ride):
    app.dependency_overrides[get_principal] = lambda: Principal('passenger', 'passenger')
    client = TestClient(app)
    response = client.post('/ride-requests', json=ride.draft.model_dump(mode='json'), headers={
        'Idempotency-Key': 'http-first-ride-0001', 'X-Guidance-Session': ride.session.session_id})
    assert response.status_code == 200, response.text
    request_id = response.json()['requestId']
    assert '_journey' not in response.json()
    assert ride.db.get('/rideRequests/' + request_id)['_journey']['legIndex'] == 0
    decide(ride, request_id, S.ACCEPTED)
    response = client.post(f'/ride-requests/{request_id}/transfer', json={
        'busNo': '22', 'sessionId': ride.session.session_id})
    assert response.status_code == 200, response.text
    assert response.json()['request']['busNo'] == '22'
    assert response.json()['request']['stopId'] == 'CJB_TRANSFER'
    assert response.json()['guidanceState']['selectedRouteNo'] == '22'
    assert '_journey' not in response.json()['request']


def test_wrong_creation_session_cannot_write_a_request(ride):
    app.dependency_overrides[get_principal] = lambda: Principal('passenger', 'passenger')
    client = TestClient(app)
    response = client.post('/ride-requests', json={**ride.draft.model_dump(mode='json'), 'stopId': 'wrong'}, headers={
        'Idempotency-Key': 'http-wrong-stop-0001', 'X-Guidance-Session': ride.session.session_id})
    assert response.status_code == 409
    assert len(ride.db.get('/rideRequests')) == 1
