import 'dart:convert';
import 'package:mobi_passenger_app/src/features/hardware_bus/concurrent_hardware_test_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/door_beacon_test_config.dart';
import 'package:mobi_passenger_app/src/services/head_tracking_direction.dart';

void main() {
  final now = DateTime.utc(2026, 11, 22, 8);
  final config = DoorBeaconTestConfig.calibrated(
    selectedBeaconId: 'TEST-BEACON',
    cameraFingerprint: 'rear|back|90',
    horizontalFovDegrees: 68,
    calibration: const HeadTrackingMountCalibration(
      mount: HeadTrackingCameraMount.headMountedCamera,
      axesAlignmentVerified: true,
      cameraAxisOffsetDegrees: 2,
    ),
  );

  test('normal hardware page uses the device profile unless one is injected',
      () {
    expect(const ConcurrentHardwareTestPage().doorBeaconTestConfig,
        same(DoorBeaconTestConfig.deviceProfile));
    expect(
        ConcurrentHardwareTestPage(doorBeaconTestConfig: config)
            .doorBeaconTestConfig,
        same(config));
  });

  test('only a complete measured profile can enable the door stream', () {
    final measured = <String, Object>{
      'selectedBeaconId': 'TEST-BEACON',
      'cameraFingerprint': 'rear|back|90',
      'mount': 'headMountedCamera',
      'axesAlignmentVerified': true,
      'cameraAxisOffsetDegrees': 2.0,
      'horizontalFovDegrees': 68,
    };
    final parsed = DoorBeaconTestConfig.fromProfile(jsonEncode(measured));
    expect(
        parsed.matches(
            activeCameraFingerprint: 'rear|back|90',
            beaconId: 'TEST-BEACON',
            beaconReceivedAt: now,
            now: now),
        isTrue);
    for (final text in [
      '',
      '{',
      '[]',
      '{}',
      jsonEncode({...measured, 'axesAlignmentVerified': false}),
      jsonEncode({...measured, 'mount': 'handheldPhone'}),
      jsonEncode({...measured, 'cameraAxisOffsetDegrees': 181}),
      jsonEncode({...measured, 'horizontalFovDegrees': 180}),
      jsonEncode({...measured, 'cameraFingerprint': ''}),
    ]) {
      expect(DoorBeaconTestConfig.fromProfile(text).enabled, isFalse);
    }
  });

  test('normal app default is disabled', () {
    expect(const DoorBeaconTestConfig.disabled().enabled, isFalse);
    expect(
        const DoorBeaconTestConfig.disabled().matches(
          activeCameraFingerprint: 'rear|back|90',
          beaconId: 'TEST-BEACON',
          beaconReceivedAt: now,
          now: now,
        ),
        isFalse);
  });

  test('only exact configured camera and selected beacon are accepted', () {
    expect(
        config.matches(
          activeCameraFingerprint: 'rear|back|90',
          beaconId: 'TEST-BEACON',
          beaconReceivedAt: now,
          now: now,
        ),
        isTrue);
    expect(
        config.matches(
          activeCameraFingerprint: 'front|front|270',
          beaconId: 'TEST-BEACON',
          beaconReceivedAt: now,
          now: now,
        ),
        isFalse);
    expect(
        config.matches(
          activeCameraFingerprint: 'rear|back|90',
          beaconId: 'OTHER',
          beaconReceivedAt: now,
          now: now,
        ),
        isFalse);
  });

  test(
      'absent, expired, future, invalid mount and unverified calibration fail closed',
      () {
    expect(
        config.matches(
            activeCameraFingerprint: 'rear|back|90',
            beaconId: 'TEST-BEACON',
            beaconReceivedAt: null,
            now: now),
        isFalse);
    expect(
        config.matches(
            activeCameraFingerprint: 'rear|back|90',
            beaconId: 'TEST-BEACON',
            beaconReceivedAt: now.subtract(const Duration(milliseconds: 1200)),
            now: now),
        isFalse);
    expect(
        config.matches(
            activeCameraFingerprint: 'rear|back|90',
            beaconId: 'TEST-BEACON',
            beaconReceivedAt: now.add(const Duration(milliseconds: 1)),
            now: now),
        isFalse);
    final handheld = DoorBeaconTestConfig.calibrated(
      selectedBeaconId: 'TEST-BEACON',
      cameraFingerprint: 'rear|back|90',
      horizontalFovDegrees: 68,
      calibration: const HeadTrackingMountCalibration(
        mount: HeadTrackingCameraMount.handheldPhone,
        axesAlignmentVerified: true,
        cameraAxisOffsetDegrees: 0,
      ),
    );
    expect(
        handheld.matches(
            activeCameraFingerprint: 'rear|back|90',
            beaconId: 'TEST-BEACON',
            beaconReceivedAt: now,
            now: now),
        isFalse);
  });
}
