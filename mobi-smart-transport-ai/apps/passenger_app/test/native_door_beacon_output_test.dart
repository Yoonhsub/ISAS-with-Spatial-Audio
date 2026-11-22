import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/native_directional_cue_output.dart';

class _CuePort implements NativeCuePort {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  @override
  Future<Map<String, dynamic>> invoke(
      String method, Map<String, dynamic> args) async =>
      {'confirmed': true, 'ready': true, 'running': false};
}

class _HeadPort implements HeadTrackedCuePort {
  final calls = <(String, Map<String, dynamic>)>[];
  bool stopConfirmed = true;

  @override
  Future<Map<String, dynamic>> invoke(
      String method, Map<String, dynamic> args) async {
    calls.add((method, Map<String, dynamic>.from(args)));
    if (method == 'stop') return {'confirmed': stopConfirmed, 'running': false};
    return {'running': true, 'spatial': true, 'pattern': 'door_demo'};
  }
}

void main() {
  test('sends actual WT and selected beacon receipt ages to native output', () async {
    final head = _HeadPort();
    final output = NativeDirectionalCueOutput(
      port: _CuePort(),
      headTrackedPort: head,
    );
    await output.prepareFromGesture();
    expect(
      await output.syncBeaconTargetStream(
        intervalMs: 800,
        azimuthDegrees: -32,
        sensorAgeMs: 83,
        beaconAgeMs: 410,
      ),
      isTrue,
    );
    expect(head.calls.single.$1, 'start');
    expect(head.calls.single.$2['pattern'], 'door_demo');
    expect(head.calls.single.$2['sensorAgeMs'], 83);
    expect(head.calls.single.$2['beaconAgeMs'], 410);
    expect(head.calls.single.$2['azimuthDegrees'], -32);
    expect(await output.syncBeaconTargetStream(
      intervalMs: 550,
      azimuthDegrees: 41,
      sensorAgeMs: 120,
      beaconAgeMs: 700,
    ), isTrue);
    expect(head.calls.last.$1, 'update');
    expect(head.calls.last.$2['sensorAgeMs'], 120);
    expect(head.calls.last.$2['beaconAgeMs'], 700);
    expect(head.calls.last.$2['azimuthDegrees'], 41);
    expect(await output.stopBeaconTargetStream(), isTrue);
    expect(head.calls.last.$1, 'stop');
  });

  test('fails closed when native stop is not confirmed', () async {
    final head = _HeadPort();
    final output = NativeDirectionalCueOutput(
      port: _CuePort(),
      headTrackedPort: head,
    );
    await output.prepareFromGesture();
    await output.syncBeaconTargetStream(
      intervalMs: 800,
      azimuthDegrees: 20,
      sensorAgeMs: 40,
      beaconAgeMs: 200,
    );
    head.stopConfirmed = false;
    await expectLater(output.stopBeaconTargetStream(), throwsStateError);
    await expectLater(
      output.syncBeaconTargetStream(
        intervalMs: 800,
        azimuthDegrees: 20,
        sensorAgeMs: 40,
        beaconAgeMs: 200,
      ),
      throwsStateError,
    );
  });

  test('rejects stale or fabricated freshness values', () async {
    final head = _HeadPort();
    final output = NativeDirectionalCueOutput(
      port: _CuePort(),
      headTrackedPort: head,
    );
    await output.prepareFromGesture();
    await expectLater(
      output.syncBeaconTargetStream(
        intervalMs: 800,
        azimuthDegrees: 0,
        sensorAgeMs: 0,
        beaconAgeMs: -1,
      ),
      throwsStateError,
    );
    expect(head.calls, isEmpty);
  });
}
