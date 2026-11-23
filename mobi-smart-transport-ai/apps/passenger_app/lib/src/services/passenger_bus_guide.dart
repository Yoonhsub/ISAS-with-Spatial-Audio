import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

import '../features/hardware_bus/continuous_beacon_scanner.dart';
import 'accepted_ride_beacon.dart';
import 'backend_api_client.dart';

typedef GuideCommand = Future<void> Function(
    String method, Map<String, Object?> arguments);

/// Owns one foreground passenger's scan. A server-confirmed ride supplies the
/// number; the beacon registry is only used to enable sound for that number.
class PassengerBusGuide extends ChangeNotifier {
  PassengerBusGuide(
      {required this.lookup,
      required this.macs,
      required this.current,
      this.selectedRide,
      this.photoDemo = false,
      this.visualOnly = false,
      this.permission = _permission,
      this.scanner = _scanner,
      this.command = _command,
      this.interval = const Duration(seconds: 5)});
  final Future<AcceptedRide?> Function() lookup;
  final Future<Set<String>> Function(String) macs;
  final bool Function() current;
  final Future<bool> Function() permission;
  final BeaconScanner Function(Set<String>) scanner;
  final GuideCommand command;
  final Duration interval;
  final RideRequestDraft? Function()? selectedRide;
  final bool photoDemo;
  final bool visualOnly;
  String? spokenClass;
  RideRequestDraft? _selection;
  bool get usingSelection => _selection != null;
  bool get _sameSelection => identical(_selection, selectedRide?.call());
  String? get cameraBus => current() && _owner != null && _sameSelection &&
      (photoDemo || hasBeacon) ? busNo : null;

  static const _audio = MethodChannel('mobi.passenger/accepted-door');
  static Future<void> _command(String name, Map<String, Object?> args) =>
      _audio.invokeMethod<void>(name, args);
  static Future<bool> _permission() async {
    final p = await const MethodChannel('mobi.passenger/hardware-permissions')
        .invokeMapMethod<String, dynamic>('request');
    return p?['granted'] == true && p?['locationEnabled'] == true;
  }

  static BeaconScanner _scanner(Set<String> ids) => ContinuousBeaconScanner(
      beaconIdResolver: (r) => r.device.remoteId.str.toUpperCase(),
      remoteIds: ids.toList(),
      smoothRssi: false, // The passenger cue filters by elapsed time in Android.
      scanTimeout: const Duration(hours: 1));

  String? busNo, _request, _owner;
  String detail = '';
  int _epoch = 0;
  int? _checking;
  bool _closed = false, _running = false, _muted = false;
  Timer? _timer;
  StreamSubscription<BeaconSignal>? _sub;
  Future<void> _draining = Future.value();
  final Set<String> _targets = {};
  DateTime? _seen;
  String? _lastMac;
  bool _manualMute = false, _priorityMute = false, _previewMute = false;
  Future<bool>? _permissionAttempt;
  bool get hasBeacon =>
      _owner != null &&
      _seen != null &&
      DateTime.now().difference(_seen!) < const Duration(seconds: 3);

  void start() {
    if (_closed || _running) return;
    _running = true;
    final epoch = ++_epoch;
    _timer = Timer.periodic(interval, (_) => unawaited(_refresh(epoch)));
    unawaited(_refresh(epoch));
  }

  bool _valid(int epoch) =>
      !_closed && _running && _epoch == epoch && current();
  Future<void> _refresh(int epoch) async {
    if (_closed || !_running || _epoch != epoch || _checking == epoch) return;
    if (!current()) {
      await stop();
      return;
    }
    _checking = epoch;
    String? number;
    try {
      final selection = selectedRide?.call();
      final ride = selection == null ? await lookup() : null;
      if (!_valid(epoch) || !identical(selection, selectedRide?.call())) return;
      number = selection?.busNo ?? ride?.busNo;
      if (number == null) {
        await _release();
        if (_valid(epoch)) _display(null, '');
        return;
      }
      if (_sameSelection && _request == ride?.requestId && busNo == number &&
          _owner != null) return;
      await _release();
      if (!_valid(epoch) || !identical(selection, selectedRide?.call())) return;
      _selection = selection;
      _request = ride?.requestId;
      _display(number, '');
      Set<String> ids;
      try {
        ids = visualOnly ? {} : await macs(number);
      } catch (_) {
        if (!photoDemo && !visualOnly) rethrow;
        ids = {};
      }
      if (!_valid(epoch) || !_sameSelection) return;
      if (!photoDemo && !visualOnly && ids.isEmpty) {
        _display(number, '등록된 시연 비콘 없음');
        return;
      }
      bool scan = false;
      if (ids.isNotEmpty) {
        try {
          scan = await (_permissionAttempt ??= permission());
        } catch (_) {
          if (!photoDemo && !visualOnly) rethrow;
        }
      }
      if (!_valid(epoch) || !_sameSelection) return;
      if (!photoDemo && !visualOnly && !scan) {
        _display(number, '주변 기기 권한과 위치 설정 확인');
        return;
      }
      final owner =
          '${identityHashCode(this)}:$epoch:${DateTime.now().microsecondsSinceEpoch}';
      _owner = owner;
      await command('begin', {'owner': owner, 'photoDemo': photoDemo, 'visualOnly': visualOnly});
      if (!_valid(epoch) || _owner != owner) {
        await command('stop', {'owner': owner});
        return;
      }
      if (_muted) await command('mute', {'owner': owner, 'value': true});
      if (!_valid(epoch) || _owner != owner) return;
      if (!scan) return;
      _targets.addAll(ids);
      _sub = scanner(ids).scan().listen((s) {
        if (!_valid(epoch) || _owner != owner || !_targets.contains(s.beaconId))
          return;
        final age = DateTime.now().difference(s.lastDetectedAt);
        if (age.isNegative ||
            age >= const Duration(seconds: 3) ||
            (_seen != null && !s.lastDetectedAt.isAfter(_seen!))) return;
        if (_lastMac != null &&
            s.beaconId != _lastMac &&
            _seen != null &&
            s.lastDetectedAt.difference(_seen!) < const Duration(seconds: 3))
          return;
        _seen = s.lastDetectedAt;
        _lastMac = s.beaconId;
        _send('beacon',
            {'rssi': s.rssi, 'at': s.lastDetectedAt.millisecondsSinceEpoch});
      }, onDone: () => _scanEnded(owner), onError: (Object _) => _scanEnded(owner));
      _display(number, '비콘 탐색 중');
    } catch (_) {
      if (_valid(epoch)) {
        await _release();
        if (_valid(epoch)) _display(number, '수락 요청 또는 비콘 상태 확인 필요');
      }
    } finally {
      if (_checking == epoch) _checking = null;
    }
  }

  void _scanEnded(String owner) {
    if (_owner != owner) return;
    if (!photoDemo && !visualOnly) { _lost(owner); return; }
    _seen = null;
    _display(busNo, '사진 시연 · 비콘 탐색 종료');
  }

  void _lost(String owner) {
    if (_owner != owner) return;
    unawaited(_release());
    if (!_closed) _display(busNo, '비콘 탐색 종료');
  }

  void _display(String? bus, String message) {
    if (_closed || busNo == bus && detail == message) return;
    busNo = bus;
    detail = message;
    notifyListeners();
  }

  void _send(String name, Map<String, Object?> args) {
    final owner = _owner;
    if (owner != null && current() && _sameSelection) {
      unawaited(command(name, {'owner': owner, ...args})
          .catchError((Object _) => _lost(owner)));
    }
  }

  void mute(bool value) {
    _manualMute = value;
    _syncMute();
  }

  void priority(bool value) {
    _priorityMute = value;
    _syncMute();
  }

  bool _visualArrival = false;

  void previewBusy(bool value, {bool arrivalAnnounced = false}) {
    if (arrivalAnnounced && !_visualArrival && _owner != null && _sameSelection) {
      _visualArrival = true;
      _send('visualArrival', {});
    }
    _previewMute = value;
    _syncMute();
  }

  void _syncMute() {
    final value = _manualMute || _priorityMute || _previewMute;
    if (value == _muted) return;
    _muted = value;
    _send('mute', {'value': value});
  }

  void clearDoor() => _send('clearDoor', {});
  void frame(Map<String, Object?> result, DateTime at, double fov) {
    if (_owner == null || (_muted && !visualOnly)) return;
    final raw = result['detections'];
    if (raw is! List || !fov.isFinite || fov <= 0 || fov >= 180) {
      clearDoor();
      return;
    }
    final rows = raw.whereType<Map>();
    final doors = rows.where((d) => d['classId'] == 'bus_door');
    final buses = rows.where((d) => d['classId'] == 'bus');
    final target = visualOnly ? rows.where((d) => d['classId'] == spokenClass &&
        d['confidence'] is num && (d['confidence'] as num) >= 0.5) : doors.isEmpty ? buses : doors;
    double? angle;
    if (target.length == 1 && (visualOnly || buses.length <= 1)) {
      final b = target.single['bbox'];
      if (b is Map && b['x'] is num && b['w'] is num) {
        final x = (b['x'] as num).toDouble(), w = (b['w'] as num).toDouble();
        if (x >= 0 && w > 0 && x + w <= 1.000000001)
          angle = (x + w / 2 - .5) * fov;
      }
    }
    if (target.length > 1 || (!visualOnly && buses.length > 1)) {
      clearDoor();
      return;
    }
    _send('frame', {'at': at.millisecondsSinceEpoch, 'angle': angle});
  }

  Future<void> _release() {
    final sub = _sub, owner = _owner;
    _sub = null;
    _owner = null;
    _visualArrival = false;
    _targets.clear();
    _seen = null;
    _lastMac = null;
    _request = null;
    _selection = null;
    final previous = _draining;
    return _draining = () async {
      await previous;
      try {
        if (owner != null) await command('stop', {'owner': owner});
      } finally {
        await sub?.cancel();
      }
    }()
        .catchError((Object _) {});
  }

  Future<void> stop() {
    _running = false;
    _epoch++;
    _timer?.cancel();
    _display(null, '');
    return _release();
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(stop());
    super.dispose();
  }
}
