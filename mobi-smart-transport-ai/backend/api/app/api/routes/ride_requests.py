from fastapi import APIRouter, Header

from app.schemas.ride_request import RideRequestCreate, RideRequestRecord, RideRequestStatusUpdate, RideTransferRequest
from app.services.ride_request_service import RideRequestService
from app.services.ride_transfer_service import RideTransferService

router = APIRouter()
_service = RideRequestService()
_transfers = RideTransferService(_service)


@router.get("", response_model=list[RideRequestRecord])
def list_my_ride_requests() -> list[RideRequestRecord]:
    return _service.list_for_passenger()


@router.post("", response_model=RideRequestRecord)
def create_ride_request(
    payload: RideRequestCreate,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
    guidance_session: str | None = Header(default=None, alias="X-Guidance-Session"),
) -> RideRequestRecord:
    journey = _transfers.journey_for_creation(guidance_session, payload) if guidance_session else None
    return _service.create(payload, idempotency_key=idempotency_key, journey=journey)


@router.post("/{requestId}/transfer")
def transfer_ride_request(requestId: str, payload: RideTransferRequest):
    return _transfers.transfer(requestId, payload.busNo, payload.sessionId)


@router.get("/{requestId}", response_model=RideRequestRecord)
def get_ride_request(requestId: str) -> RideRequestRecord:
    """docs/rw/API_CONTRACTS.md와 OpenAPI path parameter 이름을 requestId로 통일한다."""
    return _service.get(requestId)


@router.patch("/{requestId}/status", response_model=RideRequestRecord)
def update_ride_request_status(requestId: str, payload: RideRequestStatusUpdate) -> RideRequestRecord:
    """docs/rw/API_CONTRACTS.md와 OpenAPI path parameter 이름을 requestId로 통일한다."""
    return _service.update_status(requestId, payload.status)
