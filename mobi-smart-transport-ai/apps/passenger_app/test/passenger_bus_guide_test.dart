import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import 'package:mobi_passenger_app/src/services/accepted_ride_beacon.dart';
import 'package:mobi_passenger_app/src/services/backend_api_client.dart';
import 'package:mobi_passenger_app/src/services/passenger_bus_guide.dart';

class TestScanner implements BeaconScanner {
  final samples = StreamController<BeaconSignal>();
  @override
  Stream<BeaconSignal> scan({String? targetBeaconId}) => samples.stream;
  @override
  bool get isScanning => samples.hasListener;
  @override
  Future<void> stop() => samples.close();
}

const record = {
  'requestId': 'req711',
  'status': 'ACCEPTED',
  'userId': 'passenger',
  'busNo': '711',
  'routeId': 'r711',
  'stopId': 'stop',
};
void main() {
  testWidgets('approved visual guide locates the spoken object without BLE and stops on cancellation', (t) async {
    AcceptedRide? accepted = AcceptedRide.read(record, 'req711');
    final events = <(String, Map<String, Object?>)>[];
    final guide = PassengerBusGuide(visualOnly: true,
      lookup: () async => accepted, current: () => true,
      macs: (_) async => throw StateError('Visual guide must not require BLE'),
      permission: () async => throw StateError('No BLE permission required'),
      command: (name, args) async => events.add((name,args)));
    guide.start();
    await t.pump();
    expect(events.first.$2['visualOnly'], true);
    guide.spokenClass = 'pole';
    guide.frame({'detections': [
      {'classId':'bus', 'confidence':.9, 'bbox':{'x':.1,'w':.2}},
      {'classId':'pole', 'confidence':.9, 'bbox':{'x':.7,'w':.2}},
    ]}, DateTime.now(), 60);
    expect(events.last.$2['angle'], closeTo(18, .001));
    accepted = null;
    await t.pump(const Duration(seconds: 5));
    expect(events.last.$1, 'stop');
    expect(guide.busNo, isNull);
    await guide.stop();
    accepted = AcceptedRide.read(record, 'req711');
    guide.start();
    await t.pump();
    expect(events.last.$1, 'begin');
    expect(guide.busNo, '711');
    guide.dispose();
  });

  test(
      'only a complete accepted response for the same request supplies a number',
      () {
    expect(AcceptedRide.read(record, 'req711')!.busNo, '711');
    expect(AcceptedRide.read(record, 'old502'), isNull);
    for (final status in ['WAITING', 'REJECTED', 'CANCELLED', 'COMPLETED']) {
      expect(
          AcceptedRide.read({...record, 'status': status}, 'req711'), isNull);
    }
    expect(AcceptedRide.read({...record, 'busNo': ''}, 'req711'), isNull);
  });

  test('confirmed photo route guides without ride or BLE, and invalidation silences it', () async {
    RideRequestDraft? chosen = const RideRequestDraft(userId:'p', routeId:'r', busNo:'711', stopId:'s');
    var reads = 0;
    final commands = <(String, Map<String, Object?>)>[];
    final guide = PassengerBusGuide(selectedRide: () => chosen, photoDemo: true,
        lookup: () async { reads++; return null; },
        macs: (_) async => {}, current: () => true,
        command: (name,args) async => commands.add((name,args)));
    guide.start();
    await Future<void>.delayed(Duration.zero);
    expect(guide.cameraBus, '711');
    expect(commands.single.$2['photoDemo'], true);
    expect(reads, 0);
    void frame(String id, double x) => guide.frame({'detections': [
      {'classId':id,'bbox':{'x':x,'w':.2}}]}, DateTime.now(), 60);
    guide.previewBusy(true);
    guide.previewBusy(false, arrivalAnnounced: true);
    guide.previewBusy(false, arrivalAnnounced: true);
    expect(commands.skip(1).map((event) => event.$1),
        ['mute', 'visualArrival', 'mute']);
    frame('bus', .1);
    expect(commands.last.$2['angle'], closeTo(-18,.001));
    frame('bus_door', .7);
    expect(commands.last.$2['angle'], closeTo(18,.001));
    frame('pole', .4);
    expect(commands.last.$2['angle'], isNull);
    chosen = null;
    expect(guide.cameraBus, isNull);
    final count = commands.length;
    frame('bus', .1);
    expect(commands.length, count);
    guide.dispose();
  });

  testWidgets('no mapping or BLE permission still displays the approved number',
      (t) async {
    for (final ids in [
      <String>{},
      {'demo'}
    ]) {
      var prompts = 0;
      final guide = PassengerBusGuide(
          lookup: () async => AcceptedRide.read(record, 'req711'),
          current: () => true,
          macs: (_) async => ids,
          permission: () async {
            prompts++;
            return false;
          },
          scanner: (_) => throw StateError('scan must not start'));
      guide.start();
      await t.pump();
      await t.pump(const Duration(seconds: 5));
      expect(guide.busNo, '711');
      expect(prompts, ids.isEmpty ? 0 : 1);
      guide.dispose();
    }
  });

  test('approved number filters advertisements and sends signed door angles until STOP',
      () async {
    final scan = TestScanner();
    final events = <(String, Map<String, Object?>)>[];
    String? scannedNumber;
    Set<String>? scannedTargets;
    final guide = PassengerBusGuide(
        lookup: () async => AcceptedRide.read(record, 'req711'),
        macs: (number) async {
          scannedNumber = number;
          return {'A'};
        },
        current: () => true,
        permission: () async => true,
        scanner: (ids) {
          scannedTargets = ids;
          return scan;
        },
        command: (k, v) async => events.add((k, v)));
    guide.start();
    await Future<void>.delayed(Duration.zero);
    final now = DateTime.now();
    void sample(String id, DateTime at) => scan.samples.add(BeaconSignal(
        beaconId: id,
        rssi: -55,
        lastDetectedAt: at,
        estimatedDistanceMeters: null,
        signalLevel: BeaconSignalLevel.close));
    sample('B', now);
    sample('A', now.subtract(const Duration(seconds: 6)));
    await Future<void>.delayed(Duration.zero);
    expect(scannedNumber, '711');
    expect(scannedTargets, {'A'}, reason: guide.detail);
    expect(events.map((e) => e.$1), ['begin']);
    sample('A', now);
    await Future<void>.delayed(Duration.zero);
    expect(events.last.$1, 'beacon');
    expect(events.last.$2['rssi'], -55);
    void frame(double x) => guide.frame({
          'detections': [
            {
              'classId': 'bus_door',
              'bbox': {'x': x, 'w': 0.2}
            }
          ]
        }, now, 60);
    frame(.1);
    expect(events.last.$2['angle'], closeTo(-18, .001));
    frame(.7);
    expect(events.last.$2['angle'], closeTo(18, .001));
    guide.mute(true);
    frame(.2);
    expect(events.last.$1, 'mute');
    await guide.stop();
    expect(events.last.$1, 'stop');
    expect(scan.isScanning, isFalse);
    expect(guide.busNo, isNull);
    guide.dispose();
    await scan.stop();
  });

  testWidgets(
      'late accepted response cannot start output after leaving the screen',
      (t) async {
    final pending = Completer<AcceptedRide?>();
    final guide = PassengerBusGuide(
        lookup: () => pending.future,
        current: () => true,
        macs: (_) async => throw StateError('stale lookup'));
    guide.start();
    await guide.stop();
    pending.complete(AcceptedRide.read(record, 'req711'));
    await t.pump();
    expect(guide.busNo, isNull);
    guide.dispose();
  });
}
