"""Fixed demonstration dialogue; stop identities always come from the catalog."""
import logging
import re

from app.schemas.v3 import (DestinationCandidate, DestinationCandidateType,
    DestinationResolveResponse, DestinationResolveStatus, FallbackSource,
    NearbyStopCandidate, RoutePlanResponse)
from app.services.cheongju_bus_stops_service import get_shared_bus_stops_service, interactive_stop_lookup
from app.services.destination_candidate_resolver import DestinationCandidateResolver, _SEED_STOPS
from app.services.v3_agent_tools import plan_transit_route_tool
from app.services.stop_direction_service import describe_stop_directions
from app.services.route_direction_resolver import sanitize_guidance_text

QUESTION = re.compile(r"^(.+?)\s*가고\s*싶은데\s*몇\s*번\s*버스\s*타(?:야\s*(?:돼|해))?[?!.\s]*$")
BOARD = re.compile(r"^([0-9]+(?:-[0-9]+)?)\s*번\s*버스\s*탈게(?:요)?[.!?\s]*$")
PENDING = 'DEMO_STOP_CHOICE'


def stop_choices(place, live):
    if live:
        with interactive_stop_lookup():
            rows = get_shared_bus_stops_service().search_by_name(stop_name=place, limit=5)
        candidates = [NearbyStopCandidate(stopId=r.service_id, stopName=r.stop_name,
            latitude=r.latitude, longitude=r.longitude, source=FallbackSource.PUBLIC_API)
            for r in rows if compact(place) in compact(r.stop_name)]
        return describe_stop_directions(candidates)
    return [NearbyStopCandidate(stopId=r.stop_id, stopName=r.stop_name,
        latitude=r.latitude, longitude=r.longitude, source=FallbackSource.MOCK, directionHint=r.direction_hint)
        for r in _SEED_STOPS if compact(place) in compact(r.stop_name)]


def compact(text):
    return re.sub(r'\s+', '', text)


def stop_choice_label(stop):
    direction = sanitize_guidance_text(stop.directionHint or '')
    return f'{stop.stopName}, {direction}' if direction else f'{stop.stopName}, 운행 방향 확인이 필요한 정류장'


def boarding_instructions(route, *, recommended):
    parts = ['추천 경로입니다.' if recommended else '다른 경로입니다.']
    if len(route.segments) > 1:
        parts.append('버스를 한 번 갈아타는 경로입니다.')
    for index, segment in enumerate(route.segments):
        direction = sanitize_guidance_text(segment.directionHint or segment.boardStop.directionHint or '')
        direction = re.sub(r'\s*(?:방향|방면)$', '', direction)
        parts.append(f'{"타실 곳은" if index == 0 else "갈아타실 곳은"} {segment.boardStop.stopName} 정류장입니다.')
        if direction:
            parts.append(f'{direction} 방면으로 가는 {segment.routeNo}번 버스를 타세요.')
        else:
            parts.append(f'{segment.routeNo}번 버스를 타세요. 이 정류장의 운행 방향은 확인이 필요합니다.')
        if index < len(route.segments) - 1:
            parts.append(f'{segment.alightStop.stopName} 정류장에서 내려 갈아타세요.')
            if segment.alightStop.stopId == route.segments[index + 1].boardStop.stopId:
                parts.append('내린 정류장에서 다음 버스를 타시면 됩니다.')
        else:
            parts.append(f'{segment.alightStop.stopName} 정류장에서 내리세요.')
    return ' '.join(parts)


class SelectedStopResolver(DestinationCandidateResolver):
    def __init__(self, stop):
        super().__init__()
        self.stop = stop

    def resolve(self, *, heard_text, origin_lat=None, origin_lng=None, live=False):
        s = self.stop
        candidate = DestinationCandidate(name=s.stopName, type=DestinationCandidateType.STOP,
            confidence=1, stopId=s.stopId, latitude=s.latitude, longitude=s.longitude, source=s.source)
        return DestinationResolveResponse(status=DestinationResolveStatus.RESOLVED,
            heardText=heard_text, normalizedText=compact(heard_text), topCandidate=candidate,
            candidates=[candidate], destinationStops=[s],
            originStops=self._origin_stops(origin_lat=origin_lat, origin_lng=origin_lng, live=live),
            fallbackSource=s.source)


def converse(session, payload, live, text):
    """Return (message, plan, selected_bus), or None for the ordinary dialogue."""
    match = QUESTION.fullmatch(text)
    if match:
        place = match[1].strip()
        session.selected_route_no = session.selected_route_id = session.selected_stop_id = None
        session.selected_plan = session.last_route_plan = None
        session.pending_resolution_status = None
        session.pending_choice_names = []
        session.nearby_alighting_stops = []
        try:
            stops = stop_choices(place, live)
        except Exception as error:
            logging.getLogger(__name__).warning('demo_stop_lookup_failed error_type=%s', type(error).__name__)
            return '정류장 검색에 연결하지 못했습니다. 같은 질문으로 다시 시도해 주세요.', None, False
        if not stops:
            return f'{place}가 포함된 정류장을 찾지 못했습니다. 장소 이름을 다시 말씀해 주세요.', None, False
        session.pending_resolution_status = PENDING
        session.pending_origin_lat, session.pending_origin_lng = payload.originLat, payload.originLng
        session.nearby_alighting_stops = [s.model_dump(mode='json') for s in stops]
        session.pending_choice_names = [stop_choice_label(s) for s in stops]
        session.pending_heard_text = place
        session.pending_question = '내릴 정류장을 선택해 주세요. ' + ' / '.join(f'{i+1}번, {stop_choice_label(s)}' for i,s in enumerate(stops)) + '. 어떤 정류장으로 가시겠어요? 선택 번호나 방면을 말씀해 주세요.'
        return session.pending_question, None, False
    if session.pending_resolution_status == PENDING:
        stops = [NearbyStopCandidate.model_validate(s) for s in session.nearby_alighting_stops]
        answer = re.sub(r'(?:으로\s*갈게요?|이요|요)[.!?\s]*$', '', text).strip()
        ordinal = re.fullmatch(r'([0-9]+)\s*번[.!?\s]*', answer)
        chosen = stops[int(ordinal[1])-1:int(ordinal[1])] if ordinal and 1 <= int(ordinal[1]) <= len(stops) else [s for s in stops if compact(answer) in {compact(s.stopName), compact(s.directionHint or ''), compact(stop_choice_label(s))} or s.stopId == answer]
        if len(chosen) != 1:
            return session.pending_question, None, False
        lat = payload.originLat if payload.originLat is not None else session.pending_origin_lat
        lng = payload.originLng if payload.originLng is not None else session.pending_origin_lng
        if lat is None or lng is None:
            return '현재 위치를 확인하지 못했습니다. 위치 권한을 켠 뒤 정류장을 다시 선택해 주세요.', None, False
        with interactive_stop_lookup():
            plan = plan_transit_route_tool(destination_text=chosen[0].stopName,
                origin_lat=lat, origin_lng=lng, mode='live' if live else 'mock',
                resolver=SelectedStopResolver(chosen[0]))
        if plan.recommendedPlan is None:
            return plan.question or '탑승 가능한 경로를 찾지 못했습니다.', plan, False
        session.pending_resolution_status = None
        session.pending_choice_names = []
        session.pending_question = None
        # Keep the spoken route, displayed route, and later boarding confirmation
        # on the same ranked recommendation. Unspoken alternatives cannot be
        # selected accidentally by a bus number from another itinerary.
        recommended = plan.recommendedPlan
        plan = plan.model_copy(update={'plans': [recommended], 'alternatives': []})
        message = boarding_instructions(recommended, recommended=True)
        prompt = (' 먼저 탈 버스 번호로 “몇 번 버스 탈게”라고 말씀해 주세요.'
                  if len(recommended.segments) > 1
                  else ' 타실 버스를 “몇 번 버스 탈게”라고 말씀해 주세요.')
        return message + prompt, plan, False
    match = BOARD.fullmatch(text)
    if match:
        if not session.last_route_plan:
            return '먼저 목적지 정류장과 경로를 확인해 주세요.', None, False
        plan = RoutePlanResponse.model_validate(session.last_route_plan)
        routes = {r.planId:r for r in [plan.recommendedPlan, *plan.alternatives, *plan.plans]
                  if r and r.segments and r.segments[0].routeNo == match[1]}
        if not routes:
            return '안내한 경로에서 먼저 탈 버스 번호를 말씀해 주세요.', None, False
        preferred = plan.recommendedPlan
        chosen = preferred if preferred and preferred.planId in routes else next(iter(routes.values())) if len(routes) == 1 else None
        if chosen is None:
            return '같은 번호의 경로가 여러 개입니다. 탑승 정류장이 같은 추천 경로를 먼저 선택해 주세요.', None, False
        return f'{match[1]}번 버스를 선택했습니다.', plan.model_copy(update={'recommendedPlan':chosen}), True
    return None
