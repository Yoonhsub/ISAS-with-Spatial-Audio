from types import SimpleNamespace
import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from app.main import app
from app.security import Principal, current_principal
from app.schemas.ride_request import RideRequestCreate, RideRequestStatus as S
from app.services.firebase_client import get_firebase_client
from app.services.ride_request_service import RideRequestService
from app.services import demo_conversation as demo
from app.services.cheongju_bus_stops_service import CheongjuBusStopsService, TagoBusStopsService


@pytest.mark.parametrize('provider', ['tago', 'odcloud'])
def test_live_fixed_question_preserves_public_stop_ids_and_selection(monkeypatch, provider):
    monkeypatch.setattr(demo, 'describe_stop_directions', lambda stops: stops)
    monkeypatch.setenv('CHEONGJU_BUS_STOPS_ENABLED', 'true')
    monkeypatch.setenv('PUBLIC_DATA_API_KEY', 'test-key')
    def upstream(request):
        if provider == 'tago':
            assert request.extensions['timeout']['read'] == 6.0
            return httpx.Response(200, json={'response': {
                'header': {'resultCode': '00'},
                'body': {'totalCount': 2, 'pageNo': 1, 'items': {'item': [
                    {'nodeid': 'CJB1001', 'nodenm': '충북대학교병원', 'gpslati': 36.624, 'gpslong': 127.451},
                    {'nodeid': 'CJB1002', 'nodenm': '충북대학교병원', 'gpslati': 36.625, 'gpslong': 127.452},
                ]}},
            }})
        return httpx.Response(200, json={'totalCount': 2, 'data': [
            {'서비스ID': 'CJB1001', '정류소명': '충북대학교병원', '좌표(Y)': 36.624, '좌표(X)': 127.451},
            {'서비스ID': 'CJB1002', '정류소명': '충북대학교병원', '좌표(Y)': 36.625, '좌표(X)': 127.452},
        ]})
    with httpx.Client(transport=httpx.MockTransport(upstream)) as transport:
        service = (TagoBusStopsService if provider == 'tago' else CheongjuBusStopsService)(client=transport)
        monkeypatch.setattr(demo, 'get_shared_bus_stops_service', lambda: service)
        session = SimpleNamespace()
        payload = SimpleNamespace(originLat=36.63, originLng=127.43)
        message, plan, selected = demo.converse(session, payload, True,
            '충북대학교병원 가고싶은데 몇 번 버스 타')
        assert '어떤 정류장' in message
        assert 'CJB1001' not in message and 'CJB1002' not in message
        assert plan is None and selected is False
        assert [s['stopId'] for s in session.nearby_alighting_stops] == ['CJB1001', 'CJB1002']
        assert session.nearby_alighting_stops[1]['latitude'] == 36.625
        assert all(s['source'] == 'PUBLIC_API' for s in session.nearby_alighting_stops)
        captured = {}
        def plan_route(**kwargs):
            captured.update(kwargs)
            return SimpleNamespace(recommendedPlan=None, question='경로 없음')
        monkeypatch.setattr(demo, 'plan_transit_route_tool', plan_route)
        demo.converse(session, payload, True, '2번')
        assert captured['resolver'].stop.stopId == 'CJB1002'
        assert captured['mode'] == 'live'


def test_repeated_ride_cycle_preserves_history_and_ownership():
    db = get_firebase_client()
    db.clear_mock_store()
    db.set('/drivers/demo-driver', {'routeId':'r-502', 'busNo':'502'})
    service = RideRequestService(db)
    token = current_principal.set(Principal('demo-passenger', 'passenger'))
    try:
        draft = RideRequestCreate(userId='demo-passenger', routeId='r-502', busNo='502', stopId='s1')
        a = service.create(draft, 'demo-request-000001')
        assert a.targetDriverId == 'demo-driver'
        current_principal.set(Principal('demo-driver-uid','driver','demo-driver'))
        service.update_status(a.requestId, S.DENIED)
        current_principal.set(Principal('demo-passenger','passenger'))
        b = service.create(draft, 'demo-request-000002')
        assert a.requestId != b.requestId
        current_principal.set(Principal('demo-driver-uid','driver','demo-driver'))
        service.update_status(b.requestId, S.ACCEPTED)
        service.update_status(b.requestId, S.CANCELLED)
        with pytest.raises(HTTPException) as err:
            service.update_status(b.requestId, S.ACCEPTED)
        assert err.value.status_code == 409
        current_principal.set(Principal('demo-passenger','passenger'))
        assert {r.status for r in service.list_for_passenger()} == {S.DENIED,S.CANCELLED}
        current_principal.set(Principal('other','passenger'))
        assert service.list_for_passenger() == []
    finally:
        current_principal.reset(token)
        db.clear_mock_store()


def test_missing_or_ambiguous_driver_is_not_silent_success():
    db = get_firebase_client(); db.clear_mock_store()
    service = RideRequestService(db)
    draft = RideRequestCreate(userId='p', routeId='r', busNo='1', stopId='s')
    token = current_principal.set(Principal('p', 'passenger'))
    with pytest.raises(HTTPException) as err:
        service.create(draft)
    assert err.value.status_code == 409
    for key in ['d1','d2']:
        db.set('/drivers/'+key, {'routeId':'r', 'busNo':'1'})
    with pytest.raises(HTTPException): service.create(draft)
    current_principal.reset(token)
    db.clear_mock_store()


def test_fixed_question_always_asks_stop_even_for_one_exact_match(monkeypatch):
    session = SimpleNamespace()
    payload = SimpleNamespace(originLat=36.63, originLng=127.43)
    result = demo.converse(session,payload,False,'사창사거리 가고싶은데 몇 번 버스 타?')
    assert '어떤 정류장' in result[0]
    assert session.pending_resolution_status == demo.PENDING
    assert result[1] is None
    assert demo.converse(session,payload,False,'502번 버스 탈게')[1] is None
    captured = {}
    def plan(**kwargs):
        captured.update(kwargs)
        return SimpleNamespace(recommendedPlan=None,question='연결된 버스 없음')
    monkeypatch.setattr(demo, 'plan_transit_route_tool', plan)
    demo.converse(session,payload,False,'1번')
    assert captured['resolver'].stop.stopId == 'mock-stop-001'
    assert captured['origin_lat'] == 36.63


def test_stop_query_failure_never_falls_back_to_fake_live_data(monkeypatch):
    def fail(*args): raise RuntimeError('offline')
    monkeypatch.setattr(demo, 'stop_choices', fail)
    result=demo.converse(SimpleNamespace(),SimpleNamespace(originLat=None,originLng=None),True,
        '병원 가고 싶은데 몇 번 버스 타?')
    assert '연결하지 못' in result[0] and result[1] is None


def test_rest_voice_entry_uses_fixed_stop_question():
    client=TestClient(app)
    sid=client.post('/guidance/session',json={'wakeWord':'모비'}).json()['sessionId']
    response=client.post('/agent/converse',json={'sessionId':sid,'wakeWord':'모비',
        'mode':'mock','utterance':'사창사거리 가고싶은데 몇 번 버스 타?',
        'originLat':36.63,'originLng':127.43})
    assert response.status_code == 200, response.text
    assert '어떤 정류장' in response.json()['message']


def test_fixed_dialogue_selects_only_an_offered_route_and_same_boarding_stop():
    client = TestClient(app)
    sid = client.post('/guidance/session', json={'wakeWord':'모비'}).json()['sessionId']
    def say(text):
        response = client.post('/agent/converse', json={'sessionId':sid, 'wakeWord':'모비',
            'mode':'mock', 'utterance':text, 'originLat':36.6359, 'originLng':127.4597})
        assert response.status_code == 200, response.text
        return response.json()
    assert '어떤 정류장' in say('충북대학교병원 가고싶은데 몇 번 버스 타?')['message']
    planned = say('1번')
    segment = planned['routePlan']['recommendedPlan']['segments'][0]
    assert say('9999번 버스 탈게')['intent'] != 'SELECT_ARRIVAL'
    selected = say(f"{segment['routeNo']}번 버스 탈게")
    assert selected['intent'] == 'SELECT_ARRIVAL'
    state = client.get('/guidance/state', params={'sessionId':sid}).json()
    assert state['state'] == 'WAITING_FOR_BUS'
    assert state['selectedRouteId'] == segment['routeId']
    assert state['selectedStopId'] == segment['boardStop']['stopId']


@pytest.mark.parametrize("number", ["711", "502", "105", "747-1"])
def test_designated_driver_receives_passenger_selected_bus_unchanged(number):
    db = get_firebase_client(); db.clear_mock_store()
    db.set('/drivers/selected-driver', {'active':True, 'acceptsSelectedRoutes':True})
    token = current_principal.set(Principal('p', 'passenger'))
    try:
        ride = RideRequestService(db).create(RideRequestCreate(
            userId='p', routeId='route-'+number, busNo=number, stopId='selected-stop'))
        assert (ride.busNo, ride.routeId, ride.stopId, ride.targetDriverId) == (
            number, 'route-'+number, 'selected-stop', 'selected-driver')
        current_principal.set(Principal('driver-uid','driver','selected-driver'))
        service = RideRequestService(db)
        assert service.list_by_driver('selected-driver').requests[0].requestId == ride.requestId
        assert service.update_status(ride.requestId, S.ACCEPTED).busNo == number
    finally:
        current_principal.reset(token); db.clear_mock_store()


def test_specific_route_driver_precedes_general_selected_route_receiver():
    db = get_firebase_client(); db.clear_mock_store()
    db.set('/drivers/general', {'acceptsSelectedRoutes':True})
    db.set('/drivers/exact', {'routeId':'r', 'busNo':'711'})
    token = current_principal.set(Principal('p','passenger'))
    try:
        ride = RideRequestService(db).create(RideRequestCreate(userId='p',routeId='r',busNo='711',stopId='s'))
        assert ride.targetDriverId == 'exact'
    finally:
        current_principal.reset(token); db.clear_mock_store()


@pytest.mark.parametrize('profiles', [
    {'a':{'active':False,'acceptsSelectedRoutes':True}},
    {'a':{'acceptsSelectedRoutes':'true'}},
    {'a':{'acceptsSelectedRoutes':True},'b':{'acceptsSelectedRoutes':True}},
])
def test_selected_route_receiver_must_be_active_explicit_and_unique(profiles):
    db = get_firebase_client(); db.clear_mock_store()
    db.set('/drivers', profiles)
    token=current_principal.set(Principal('p','passenger'))
    try:
        with pytest.raises(HTTPException) as error:
            RideRequestService(db).create(RideRequestCreate(userId='p',routeId='r',busNo='711',stopId='s'))
        assert error.value.status_code == 409
    finally:
        current_principal.reset(token); db.clear_mock_store()
