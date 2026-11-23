"""Name platform directions using verified downstream stops, never stop IDs or seeds."""
import os
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import unquote

from app.schemas.v3 import NearbyStopCandidate
from app.services.route_direction_resolver import sanitize_guidance_text
from app.services.vision_binding_service import vision_binding_service
from services.public_data.public_data_client import BusRouteService


def describe_stop_directions(stops: list[NearbyStopCandidate], *, route_service=None) -> list[NearbyStopCandidate]:
    if not stops or vision_binding_service.has_camera_reservation():
        return stops
    owned = route_service is None
    service = route_service or BusRouteService(api_key=unquote(os.getenv('PUBLIC_DATA_API_KEY', '')))
    # At most five spoken choices and two shared route sequences. No retries.
    def routes(stop):
        try:
            return stop.stopId, service.routes_serving_stop('33010', stop.stopId, timeout=6.0)
        except Exception:
            return stop.stopId, {}
    def sequence(route_id):
        try:
            result = service.get_route_stops('33010', route_id, verify_page=True, timeout=6.0)
            return route_id, sorted(result.nodes, key=lambda node: node.nodeOrd)
        except Exception:
            return route_id, []
    try:
        with ThreadPoolExecutor(max_workers=4) as pool:
            serving = dict(pool.map(routes, stops[:5]))
            route_ids = {key for mapping in serving.values() for key in mapping}
            ranked = sorted(route_ids, key=lambda key: (-sum(key in mapping for mapping in serving.values()), key))[:2]
            sequences = dict(pool.map(sequence, ranked))
        described = []
        for stop in stops:
            next_names = []
            for route_id, nodes in sequences.items():
                if route_id not in serving.get(stop.stopId, {}):
                    continue
                positions = [index for index, node in enumerate(nodes) if node.nodeId == stop.stopId]
                # Repeated nodes on a loop and terminal stops do not imply a direction.
                if len(positions) != 1 or positions[0] + 1 >= len(nodes):
                    continue
                following = nodes[positions[0] + 1]
                name = sanitize_guidance_text(following.nodeNm)
                if name and name != stop.stopName and following.nodeId != stop.stopId and name not in next_names:
                    next_names.append(name)
            hint = '·'.join(next_names) + ' 방면' if next_names else None
            described.append(stop.model_copy(update={'directionHint': hint}))
        return described
    finally:
        if owned:
            service.close()
