import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../services/head_tracking_direction.dart';

/// Camera and beacon identifiers for one measured camera mount.
@immutable
class DoorBeaconTestConfig {
  const DoorBeaconTestConfig.disabled()
      : enabled = false,
        selectedBeaconId = '',
        cameraFingerprint = '',
        horizontalFovDegrees = 0,
        calibration = const HeadTrackingMountCalibration();

  const DoorBeaconTestConfig.calibrated({
    required this.selectedBeaconId,
    required this.cameraFingerprint,
    required this.horizontalFovDegrees,
    required this.calibration,
  }) : enabled = true;

  static final deviceProfile = DoorBeaconTestConfig.fromProfile(
    const String.fromEnvironment('MOBI_DOOR_BEACON_CALIBRATION'),
  );

  factory DoorBeaconTestConfig.fromProfile(String profile) {
    const disabled = DoorBeaconTestConfig.disabled();
    if (profile.isEmpty) return disabled;
    final Object? data;
    try {
      data = jsonDecode(profile);
    } on FormatException {
      return disabled;
    }
    if (data is! Map<String, dynamic>) return disabled;
    final beacon = data['selectedBeaconId'];
    final camera = data['cameraFingerprint'];
    final fov = data['horizontalFovDegrees'];
    final offset = data['cameraAxisOffsetDegrees'];
    final mount = switch (data['mount']) {
      'fixedWorldCamera' => HeadTrackingCameraMount.fixedWorldCamera,
      'headMountedCamera' => HeadTrackingCameraMount.headMountedCamera,
      _ => HeadTrackingCameraMount.unverified,
    };
    if (beacon is! String ||
        beacon.trim().isEmpty ||
        camera is! String ||
        camera.trim().isEmpty ||
        fov is! num ||
        !fov.isFinite ||
        fov <= 0 ||
        fov >= 180 ||
        offset is! num) {
      return disabled;
    }
    final calibration = HeadTrackingMountCalibration(
      mount: mount,
      axesAlignmentVerified: data['axesAlignmentVerified'] == true,
      cameraAxisOffsetDegrees: offset.toDouble(),
    );
    if (!calibration.verified) return disabled;
    return DoorBeaconTestConfig.calibrated(
      selectedBeaconId: beacon,
      cameraFingerprint: camera,
      horizontalFovDegrees: fov.toDouble(),
      calibration: calibration,
    );
  }

  final bool enabled;
  final String selectedBeaconId;
  final String cameraFingerprint;
  final double horizontalFovDegrees;
  final HeadTrackingMountCalibration calibration;

  bool matches({
    required String? activeCameraFingerprint,
    required String? beaconId,
    required DateTime? beaconReceivedAt,
    required DateTime now,
    Duration maxBeaconAge = const Duration(milliseconds: 1200),
  }) {
    if (!enabled ||
        selectedBeaconId.isEmpty ||
        cameraFingerprint.isEmpty ||
        activeCameraFingerprint != cameraFingerprint ||
        beaconId != selectedBeaconId ||
        beaconReceivedAt == null ||
        !calibration.verified ||
        calibration.mount == HeadTrackingCameraMount.handheldPhone ||
        !horizontalFovDegrees.isFinite ||
        horizontalFovDegrees <= 0 ||
        horizontalFovDegrees >= 180) {
      return false;
    }
    final age = now.toUtc().difference(beaconReceivedAt.toUtc());
    return !age.isNegative && age < maxBeaconAge;
  }
}

/// Receipt copied only from the currently selected, generation-filtered scan.
@immutable
class DoorBeaconTestReceipt {
  const DoorBeaconTestReceipt({
    required this.beaconId,
    required this.rssi,
    required this.receivedAt,
    required this.scanGeneration,
  });

  final String beaconId;
  final int rssi;
  final DateTime receivedAt;
  final int scanGeneration;
}
