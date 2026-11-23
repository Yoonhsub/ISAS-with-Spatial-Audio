from threading import Event
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.schemas.v3 import DestinationCandidate, DestinationResolveResponse, NearbyStopCandidate
from app.services.cheongju_route_planner import CheongjuRoutePlanner
from app.services.route_stop_sequence_cache import RouteStopSequenceCache, _bounded_lookup
from app.services import demo_conversation as demo
from services.public_data.public_data_client.schemas import NormalizedBusRouteNode, NormalizedBusRouteStopsResponse


def stop(identifier, name, latitude):
    return NearbyStopCandidate(stopId=identifier, stopName=name, latitude=latitude,
                               longitude=127.45, source='PUBLIC_API')


class Fixture:
    def __init__(self, monkeypatch):
        monkeypatch.setenv('CHEONGJU_ROUTE_PLAN_ROUTE_NOS', 'auto')
        monkeypatch.setenv('CHEONGJU_BUS_STOPS_PROVIDER', 'tago')
        self.origin = stop('CJB_ORIGIN', '출발 정류장', 36.60)
        self.destination = stop('CJB_DESTINATION', '청주대학교', 36.65)
        self.transfer = stop('CJB_TRANSFER', '환승 정류장', 36.63)
        self.catalog = {'CJB_ORIGIN': {'CJB_A': '11'}, 'CJB_DESTINATION': {'CJB_B': '22'}}
        self.nodes = {'CJB_A': [self.origin, self.transfer], 'CJB_B': [self.transfer, self.destination]}
        self.calls = []
        self.failed = set()
        self.resolution = DestinationResolveResponse(
            status='RESOLVED', heardText='청주대학교', normalizedText='청주대학교',
            topCandidate=DestinationCandidate(name='청주대학교', type='STOP', confidence=1,
                stopId=self.destination.stopId, latitude=36.65, longitude=127.45, source='PUBLIC_API'),
            originStops=[self.origin], destinationStops=[self.destination], fallbackSource='PUBLIC_API')
        service = SimpleNamespace(routes_serving_stop=self.routes, get_route_stops=self.sequence)
        self.cache = RouteStopSequenceCache(route_service=service)
        self.planner = CheongjuRoutePlanner(sequence_cache=self.cache,
            resolver=SimpleNamespace(resolve=lambda **_: self.resolution))

    def routes(self, city, stop_id, *, timeout=None):
        assert city == '33010'
        self.calls.append(('routes', stop_id))
        if stop_id in self.failed:
            raise RuntimeError('provider unavailable')
        return self.catalog.get(stop_id, {})

    def sequence(self, city, route_id, *, verify_page, timeout=None):
        assert city == '33010' and verify_page
        self.calls.append(('sequence', route_id))
        if route_id in self.failed:
            raise RuntimeError('provider unavailable')
        return NormalizedBusRouteStopsResponse(routeId=route_id, nodes=[
            NormalizedBusRouteNode(nodeId=s.stopId, nodeNm=s.stopName, nodeOrd=i)
            for i, s in enumerate(self.nodes.get(route_id, []), 1)])

    def plan(self, **kwargs):
        return self.planner.plan(heard_text='청주대학교', origin_lat=36.60, origin_lng=127.45, live=True, **kwargs)


def test_live_no_direct_route_finds_verified_forward_transfer(monkeypatch):
    f = Fixture(monkeypatch)
    result = f.plan()
    assert result.status.value == 'RESOLVED'
    assert result.recommendedPlan.type.value == 'ONE_TRANSFER'
    assert result.recommendedPlan.transferCount == 1
    first, second = result.recommendedPlan.segments
    assert (first.routeNo, second.routeNo) == ('11', '22')
    assert first.alightStop.stopId == second.boardStop.stopId == 'CJB_TRANSFER'
    assert first.boardStop.stopId == 'CJB_ORIGIN'
    assert second.alightStop.stopId == 'CJB_DESTINATION'
    assert result.fallbackSource.value == 'PUBLIC_API'
    assert result.rawProviderEvidence['searchedTransferCount'] == 1
    assert result.rawProviderEvidence['transferSameStopOnly'] is True


@pytest.mark.parametrize('reversed_route', ['CJB_A', 'CJB_B'])
def test_transfer_must_run_forward_on_both_legs(monkeypatch, reversed_route):
    f = Fixture(monkeypatch)
    f.nodes[reversed_route].reverse()
    result = f.plan()
    assert result.recommendedPlan is None
    assert '한 번 갈아타는 경로' in result.question


def test_same_name_opposite_platform_is_not_a_verified_transfer(monkeypatch):
    f = Fixture(monkeypatch)
    f.nodes['CJB_B'][0] = stop('CJB_OTHER_SIDE', f.transfer.stopName, 36.63)
    assert f.plan().recommendedPlan is None


def test_direct_route_still_wins_without_extra_transfer_queries(monkeypatch):
    f = Fixture(monkeypatch)
    f.catalog['CJB_DESTINATION']['CJB_A'] = '11'
    f.nodes['CJB_A'].append(f.destination)
    result = f.plan()
    assert result.recommendedPlan.type.value == 'DIRECT'
    assert result.rawProviderEvidence['searchedTransferCount'] == 0
    assert f.calls == [('routes', 'CJB_ORIGIN'), ('routes', 'CJB_DESTINATION'), ('sequence', 'CJB_A')]


def test_transfer_expands_to_additional_nearby_boarding_stops(monkeypatch):
    f = Fixture(monkeypatch)
    f.resolution.originStops = [stop('CJB_EMPTY1', '가까운 정류장1', 36.60),
                               stop('CJB_EMPTY2', '가까운 정류장2', 36.60), f.origin]
    assert f.plan().recommendedPlan.segments[0].boardStop.stopId == f.origin.stopId


def test_only_fully_fetched_routes_are_used_when_other_route_fails(monkeypatch):
    f = Fixture(monkeypatch)
    f.catalog['CJB_ORIGIN']['CJB_BAD'] = '99'
    f.failed.add('CJB_BAD')
    result = f.plan()
    assert result.recommendedPlan is not None
    assert result.rawProviderEvidence['transferSearchPartial'] is True
    assert {s.routeNo for p in result.plans for s in p.segments} == {'11', '22'}


def test_failure_is_reported_as_incomplete_search_not_no_such_bus(monkeypatch):
    f = Fixture(monkeypatch)
    f.failed.add('CJB_B')
    result = f.plan()
    assert result.recommendedPlan is None
    assert result.fallbackSource.value == 'ERROR'
    assert '일부 노선 정보' in result.question
    assert not any('mock' in str(call) for call in f.calls)


def test_requested_bus_filters_first_leg_and_keeps_other_transfer_number(monkeypatch):
    f = Fixture(monkeypatch)
    assert [s.routeNo for s in f.plan(route_no='11').recommendedPlan.segments] == ['11', '22']
    assert f.plan(route_no='22').recommendedPlan is None


def test_bounded_lookup_reports_deadline_and_never_invents_missing_result():
    release = Event()
    try:
        results, partial = _bounded_lookup(['slow'], lambda _: release.wait(1), seconds=.01)
        assert results == {} and partial
    finally:
        release.set()


def test_route_discovery_caps_provider_calls_and_exposes_limit(monkeypatch):
    f = Fixture(monkeypatch)
    f.catalog['CJB_ORIGIN'].update({f'CJB_EXTRA{i}': str(i + 100) for i in range(20)})
    result = f.plan()
    assert result.recommendedPlan is not None
    assert result.rawProviderEvidence['transferRouteLimitReached'] is True
    assert len([c for c in f.calls if c[0] == 'sequence']) <= 24


def test_fixed_voice_flow_explains_both_legs_and_only_confirms_first_bus(monkeypatch):
    f = Fixture(monkeypatch)
    monkeypatch.setattr(demo, 'stop_choices', lambda *_: [f.destination])
    monkeypatch.setattr(demo, 'plan_transit_route_tool', lambda **_: f.plan())
    client = TestClient(app)
    sid = client.post('/guidance/session', json={'wakeWord': '모비'}).json()['sessionId']

    def say(text):
        response = client.post('/agent/converse', json={'sessionId': sid, 'wakeWord': '모비',
            'mode': 'live', 'utterance': text, 'originLat': 36.60, 'originLng': 127.45})
        assert response.status_code == 200, response.text
        return response.json()

    say('청주대학교 가고싶은데 몇 번 버스 타?')
    answer = say('1번')['message']
    assert all(text in answer for text in ['한 번 갈아타는', '11번 버스', '22번 버스',
        '환승 정류장', '내린 정류장에서', '청주대학교', '먼저 탈 버스 번호'])
    assert 'CJB_' not in answer
    assert say('22번 버스 탈게')['intent'] != 'SELECT_ARRIVAL'
    assert say('11번 버스 탈게')['intent'] == 'SELECT_ARRIVAL'
    state = client.get('/guidance/state', params={'sessionId': sid}).json()
    assert (state['selectedRouteId'], state['selectedStopId']) == ('CJB_A', 'CJB_ORIGIN')
    assert len(state['selectedPlan']['segments']) == 2


@pytest.mark.parametrize('direct', [False, True])
def test_voice_offers_one_ranked_route_and_cannot_board_unspoken_alternative(monkeypatch, direct):
    f = Fixture(monkeypatch)
    full_plan = f.plan()
    recommended = full_plan.recommendedPlan
    if direct:
        from app.schemas.v3 import RoutePlanType
        first = recommended.segments[0].model_copy(update={
            'alightStop': recommended.segments[-1].alightStop})
        recommended = recommended.model_copy(update={
            'type': RoutePlanType.DIRECT, 'transferCount': 0, 'segments': [first]})
    alternate_segments = [segment.model_copy(update={'routeNo': str(33 + index * 11),
        'routeId': f'CJB_ALTERNATIVE_{index}'}) for index, segment in enumerate(recommended.segments)]
    alternative = recommended.model_copy(update={'planId': 'alternative', 'segments': alternate_segments})
    # The ranked recommendation wins even if it is not first in the raw list.
    full_plan = full_plan.model_copy(update={'plans': [alternative, recommended],
        'alternatives': [alternative], 'recommendedPlan': recommended})
    monkeypatch.setattr(demo, 'stop_choices', lambda *_: [f.destination])
    monkeypatch.setattr(demo, 'plan_transit_route_tool', lambda **_: full_plan)
    client = TestClient(app)
    sid = client.post('/guidance/session', json={'wakeWord': '모비'}).json()['sessionId']

    def say(text):
        response = client.post('/agent/converse', json={'sessionId': sid, 'wakeWord': '모비',
            'mode': 'live', 'utterance': text, 'originLat': 36.60, 'originLng': 127.45})
        assert response.status_code == 200, response.text
        return response.json()

    say('청주대학교 가고싶은데 몇 번 버스 타?')
    response = say('1번')
    message, route = response['message'], response['routePlan']
    assert message.count('추천 경로입니다.') == 1
    assert all(text not in message for text in ['다른 경로', '33번', '44번', 'CJB_'])
    assert ('한 번 갈아타는' in message) is not direct
    assert ('22번 버스' in message) is not direct
    assert '11번 버스' in message and '청주대학교' in message
    assert message.count('몇 번 버스 탈게') == 1
    assert route['plans'] == [route['recommendedPlan']] and route['alternatives'] == []
    assert len(full_plan.plans) == 2 and len(full_plan.alternatives) == 1
    assert say('33번 버스 탈게')['intent'] != 'SELECT_ARRIVAL'
    assert say('11번 버스 탈게')['intent'] == 'SELECT_ARRIVAL'
    state = client.get('/guidance/state', params={'sessionId': sid}).json()
    assert (state['selectedRouteId'], state['selectedStopId']) == ('CJB_A', 'CJB_ORIGIN')
    assert [s['routeNo'] for s in state['selectedPlan']['segments']] == (['11'] if direct else ['11', '22'])
