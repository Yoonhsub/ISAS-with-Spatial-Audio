from types import SimpleNamespace
import httpx
import pytest
from app.schemas.v3 import NearbyStopCandidate, FallbackSource
from app.services.stop_direction_service import describe_stop_directions
from app.services.demo_conversation import converse, boarding_instructions, PENDING
from app.services import demo_conversation
from app.services.vision_binding_service import vision_binding_service
from services.public_data.public_data_client import BusRouteService


def candidates():
    return [NearbyStopCandidate(stopId=key, stopName='병원', latitude=36.6,
        longitude=127.4, source=FallbackSource.PUBLIC_API) for key in ['CJB001','CJB002']]


def response(rows):
    return httpx.Response(200,json={'response': {'header': {'resultCode':'00'},
        'body': {'totalCount':len(rows),'pageNo':1,'items':{'item':rows}}}})


def test_direction_is_the_verified_next_stop_not_the_opposite_platform_or_route_end():
    def upstream(request):
        assert request.extensions['timeout']['read']==6.0
        if request.url.path.endswith('getSttnThrghRouteList'):
            return response([{'routeid':'route1','routeno':'711'}])
        return response([
            {'nodeid':'CJB001','nodenm':'병원','nodeord':1},
            {'nodeid':'CJB003','nodenm':'시청','nodeord':2},
            {'nodeid':'CJB002','nodenm':'병원','nodeord':3},
            {'nodeid':'CJB004','nodenm':'터미널','nodeord':4},
        ])
    with httpx.Client(transport=httpx.MockTransport(upstream)) as client:
        service=BusRouteService(api_key='test',client=client)
        result=describe_stop_directions(candidates(),route_service=service)
    assert [s.directionHint for s in result]==['시청 방면','터미널 방면']
    assert [s.stopId for s in result]==['CJB001','CJB002']


@pytest.mark.parametrize('mode',['failure','terminal','repeated'])
def test_unverified_terminal_or_repeated_stop_never_gets_an_invented_direction(mode):
    def upstream(request):
        if mode=='failure': raise httpx.ReadTimeout('timeout')
        if request.url.path.endswith('getSttnThrghRouteList'):
            return response([{'routeid':'route1','routeno':'711'}])
        rows=[{'nodeid':'CJB001','nodenm':'병원','nodeord':1}]
        if mode=='repeated': rows += [
            {'nodeid':'CJB003','nodenm':'시청','nodeord':2},
            {'nodeid':'CJB001','nodenm':'병원','nodeord':3},
            {'nodeid':'CJB004','nodenm':'터미널','nodeord':4}]
        return response(rows)
    with httpx.Client(transport=httpx.MockTransport(upstream)) as client:
        service=BusRouteService(api_key='test',client=client)
        assert all(s.directionHint is None for s in describe_stop_directions(candidates(),route_service=service))


def test_camera_active_direction_lookup_does_not_use_network(monkeypatch):
    monkeypatch.setattr(vision_binding_service,'has_camera_reservation',lambda:True)
    class Forbidden:
        def routes_serving_stop(self,*args,**kwargs): raise AssertionError('network forbidden')
    assert describe_stop_directions(candidates(),route_service=Forbidden())==candidates()


def test_spoken_stop_choice_accepts_direction_and_never_reads_internal_ids(monkeypatch):
    stops=[s.model_copy(update={'directionHint':hint}) for s,hint in zip(candidates(),['시청 방면','터미널 방면'])]
    monkeypatch.setattr(demo_conversation,'stop_choices',lambda *args:stops)
    session=SimpleNamespace()
    payload=SimpleNamespace(originLat=36.6,originLng=127.4)
    message,_,_=converse(session,payload,True,'병원 가고싶은데 몇 번 버스 타')
    assert '내릴 정류장' in message and '시청 방면' in message and '터미널 방면' in message
    assert 'CJB' not in message and session.pending_resolution_status==PENDING
    captured={}
    def plan(**kwargs):
        captured.update(kwargs)
        return SimpleNamespace(recommendedPlan=None,question='경로 없음')
    monkeypatch.setattr(demo_conversation,'plan_transit_route_tool',plan)
    converse(session,payload,True,'터미널 방면으로 갈게')
    assert captured['resolver'].stop.stopId=='CJB002'


def test_boarding_announcement_distinguishes_boarding_direction_bus_and_alighting():
    route=SimpleNamespace(segments=[SimpleNamespace(routeNo='711',
        boardStop=SimpleNamespace(stopName='사창사거리',directionHint=None),
        alightStop=SimpleNamespace(stopName='충북대학교병원'),directionHint='시청·병원 방향')])
    message=boarding_instructions(route,recommended=True)
    assert '타실 곳은 사창사거리 정류장' in message
    assert '시청·병원 방면으로 가는 711번' in message
    assert '충북대학교병원 정류장에서 내리세요' in message
