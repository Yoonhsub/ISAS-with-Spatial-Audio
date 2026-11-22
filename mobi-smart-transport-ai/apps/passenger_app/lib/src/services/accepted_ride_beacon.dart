/// Identity supplied by the authenticated request-status response.
class AcceptedRide {
  const AcceptedRide._(
      this.requestId, this.userId, this.routeId, this.busNo, this.stopId);
  final String requestId, userId, routeId, busNo, stopId;

  static AcceptedRide? read(Map<String, dynamic> record, String expectedId) {
    if (record['status'] != 'ACCEPTED' || record['requestId'] != expectedId) {
      return null;
    }
    for (final key in ['userId', 'routeId', 'busNo', 'stopId']) {
      if (record[key] is! String || (record[key] as String).trim().isEmpty) {
        return null;
      }
    }
    return AcceptedRide._(expectedId, record['userId'], record['routeId'],
        record['busNo'], record['stopId']);
  }
}
