import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'directional_guidance.dart';
import 'spatial_verification_engine.dart';

abstract interface class NativeCuePort {
  Future<Map<String, dynamic>> invoke(String method, Map<String, dynamic> args);
  Stream<Map<String, dynamic>> get events;
}

abstract interface class HeadTrackedCuePort {
  Future<Map<String, dynamic>> invoke(String method, Map<String, dynamic> args);
}

class _AndroidHeadTrackedCuePort implements HeadTrackedCuePort {
  static final instance = _AndroidHeadTrackedCuePort();
  final _channel = const MethodChannel('mobi.passenger/hardware-tone');
  @override
  Future<Map<String, dynamic>> invoke(
      String method, Map<String, dynamic> args) async {
    final result =
        await _channel.invokeMapMethod<String, dynamic>(method, args);
    if (result == null) throw StateError('HRTF acknowledgement missing');
    return result;
  }
}

/// One channel handler per Activity; old page disposal cannot remove a new handler.
class _AndroidCuePort implements NativeCuePort {
  _AndroidCuePort() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cueFinished' && call.arguments is Map) {
        _events.add(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
  }
  static final instance = _AndroidCuePort();
  final _channel = const MethodChannel('mobi/local_android_audio');
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<Map<String, dynamic>> invoke(
      String method, Map<String, dynamic> args) async {
    final result =
        await _channel.invokeMapMethod<String, dynamic>(method, args);
    if (result == null) {
      throw StateError('Native audio acknowledgement missing');
    }
    return result;
  }
}

/// Shared Android cue owner. Ordinary cues stay unchanged; its opt-in door
/// stream requires caller-supplied fresh WT/visual bearings and confirmed stop.
class NativeDirectionalCueOutput
    implements
        SpatialTestOutput,
        DirectionalCueOutput,
        HeadTrackedCueOutput,
        ContinuousBeaconTargetOutput,
        InformationalDirectionalCueOutput {
  NativeDirectionalCueOutput(
      {NativeCuePort? port, HeadTrackedCuePort? headTrackedPort})
      : _port = port ?? _AndroidCuePort.instance,
        _headTrackedPort =
            headTrackedPort ?? _AndroidHeadTrackedCuePort.instance,
        _owner = 'audio-${DateTime.now().microsecondsSinceEpoch}-${++_owners}' {
    _subscription = _port.events.listen(_event);
  }
  static int _owners = 0;
  final NativeCuePort _port;
  final HeadTrackedCuePort _headTrackedPort;
  final String _owner;
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  int _id = 0;
  bool _closed = false,
      _ready = false,
      _uncertain = false,
      _headTrackedActive = false,
      _continuousBeaconStream = false,
      _beaconStreamRequested = false;
  int _beaconRevision = 0;
  Completer<bool>? _playing;
  Future<void>? _stopBarrier, _disposing;
  Map<String, dynamic> _probe = {
    'phase': 'idle',
    'active': false,
    'contextState': 'native-stereo'
  };
  Map<String, dynamic> _args([Map<String, dynamic> values = const {}]) =>
      {'owner': _owner, ...values};
  void recordTtsEvent(String value) {
    if (!_closed) _probe = {..._probe, 'ttsEvent': value};
  }

  void _ensureOpen() {
    if (_closed || _uncertain) {
      throw StateError('Native output closed or unconfirmed');
    }
  }

  @override
  Future<void> prepareFromGesture() async {
    _ensureOpen();
    final data = await _port.invoke('prepare', _args());
    _ensureOpen();
    _ready = true;
    _probe = {..._probe, ...data, 'phase': 'ready'};
  }

  @override
  Future<bool> play(String mode, String direction) {
    if (mode != 'STEREO') {
      throw UnsupportedError('Android stereo only; HRTF unverified');
    }
    final d = switch (direction) {
      'LEFT' => TestDirection.left,
      'CENTER' => TestDirection.center,
      'RIGHT' => TestDirection.right,
      _ => throw ArgumentError('Unknown test direction')
    };
    return playCue(d);
  }

  @override
  Future<bool> playCue(TestDirection direction) => _playStereo(direction);

  @override
  Future<bool> playInformationalCue(
          TestDirection direction, InformationalCueTone tone) =>
      _playStereo(direction, tone: tone);

  Future<bool> _playStereo(TestDirection direction,
      {InformationalCueTone? tone}) async {
    _ensureOpen();
    if (_beaconStreamRequested || _continuousBeaconStream) {
      await stopBeaconTargetStream();
    }
    if (!_ready || _playing != null || _stopBarrier != null) {
      throw StateError('Prepare first; simultaneous cues forbidden');
    }
    final id = ++_id, pending = Completer<bool>();
    _playing = pending;
    // Native errors can arrive before the method reply. Preserve the error for
    // the caller while observing it immediately during that handshake.
    unawaited(pending.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _probe = {
      ..._probe,
      'phase': 'starting',
      'active': true,
      'runId': id,
      'direction': direction.name
    };
    try {
      final data = await _port.invoke(
          'play',
          _args({
            'id': id,
            'direction': direction.name.toUpperCase(),
            if (tone != null) 'informationalTone': tone.name
          }));
      if (!_closed && id == _id && identical(_playing, pending)) {
        _probe = {..._probe, ...data, 'phase': 'playing'};
      }
    } catch (error, stack) {
      if (identical(_playing, pending)) {
        _playing = null;
        _uncertain = true;
        _probe = {
          ..._probe,
          'phase': 'failed',
          'active': 'unknown',
          'error': error.runtimeType.toString()
        };
        // Also observe a synchronous start failure; no unhandled Future error.
        if (!pending.isCompleted) pending.complete(false);
      }
      Error.throwWithStackTrace(error, stack);
    }
    return pending.future;
  }

  @override
  Future<bool> playHeadTrackedCue(double azimuthDegrees) async {
    _ensureOpen();
    if (_beaconStreamRequested || _continuousBeaconStream) {
      await stopBeaconTargetStream();
    }
    if (!_ready ||
        _playing != null ||
        _stopBarrier != null ||
        !azimuthDegrees.isFinite ||
        azimuthDegrees < -180 ||
        azimuthDegrees > 180) {
      throw StateError('Prepare first; valid exclusive HRTF cue required');
    }
    final id = ++_id, pending = Completer<bool>();
    _playing = pending;
    unawaited(
      pending.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    try {
      // The native start might be underway before its reply reaches Dart.
      _headTrackedActive = true;
      final data = await _headTrackedPort.invoke('start', {
        'left': .7071067811865476,
        'right': .7071067811865476,
        'sensorAgeMs': 0,
        'intervalMs': 1000,
        'beaconAgeMs': -1,
        'pattern': 'warning',
        'azimuthDegrees': azimuthDegrees,
      });
      if (_closed || id != _id || !identical(_playing, pending)) {
        return pending.future;
      }
      if (data['running'] != true) {
        throw StateError(data['reason'] ?? 'HRTF start not confirmed');
      }
      _probe = {
        ..._probe,
        ...data,
        'phase': 'playing',
        'active': true,
        'runId': id,
        'direction': 'HEAD_TRACKED',
        'azimuthDegrees': azimuthDegrees,
      };
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (_closed || id != _id || !identical(_playing, pending)) {
        return pending.future;
      }
      final stopped = await _headTrackedPort.invoke('stop', const {});
      if (stopped['confirmed'] != true) {
        throw StateError('HRTF stop not confirmed');
      }
      _headTrackedActive = false;
      _playing = null;
      _probe = {..._probe, ...stopped, 'phase': 'completed', 'active': false};
      pending.complete(true);
    } catch (error, stack) {
      if (identical(_playing, pending)) {
        _playing = null;
        _uncertain = true;
        if (!pending.isCompleted) pending.completeError(error, stack);
      }
      Error.throwWithStackTrace(error, stack);
    }
    return pending.future;
  }

  @override
  Future<bool> syncBeaconTargetStream({
    required int intervalMs,
    required double azimuthDegrees,
    required int sensorAgeMs,
    required int beaconAgeMs,
  }) async {
    _ensureOpen();
    if (!_ready ||
        _playing != null ||
        _stopBarrier != null ||
        !_validBeaconParameters(
            intervalMs, azimuthDegrees, sensorAgeMs, beaconAgeMs)) {
      throw StateError('Fresh verified door, WT and selected beacon required');
    }
    final revision = ++_beaconRevision;
    _beaconStreamRequested = true;
    final wasActive = _continuousBeaconStream;
    // Native start/update can already be active before the reply arrives.
    _headTrackedActive = true;
    try {
      final data = await _headTrackedPort.invoke(wasActive ? 'update' : 'start', {
        'left': .7071067811865476,
        'right': .7071067811865476,
        'sensorAgeMs': sensorAgeMs,
        'intervalMs': intervalMs,
        'beaconAgeMs': beaconAgeMs,
        'pattern': 'door_demo',
        'azimuthDegrees': azimuthDegrees,
      });
      if (revision != _beaconRevision || _closed) {
        final stopped = await _headTrackedPort.invoke('stop', const {});
        if (stopped['confirmed'] != true) {
          _uncertain = true;
          throw StateError('Cancelled door stream stop not confirmed');
        }
        _headTrackedActive = false;
        _continuousBeaconStream = false;
        _beaconStreamRequested = false;
        return false;
      }
      if (data['running'] != true || data['spatial'] != true) {
        throw StateError(data['reason'] ?? 'Door audio start not confirmed');
      }
      _continuousBeaconStream = true;
      _probe = {
        ..._probe,
        ...data,
        'phase': 'door-beacon-streaming',
        'active': true,
        'sensorAgeMs': sensorAgeMs,
        'beaconAgeMs': beaconAgeMs,
        'intervalMs': intervalMs,
        'azimuthDegrees': azimuthDegrees,
      };
      return true;
    } catch (error, stack) {
      _beaconStreamRequested = false;
      _uncertain = true;
      try {
        await stopBeaconTargetStream();
      } catch (_) {
        // Keep output uncertain if native stop cannot be acknowledged.
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  bool _validBeaconParameters(
      int interval, double angle, int sensorAge, int beaconAge) =>
      interval >= 250 &&
      interval <= 1400 &&
      angle.isFinite &&
      angle >= -180 &&
      angle <= 180 &&
      sensorAge >= 0 &&
      sensorAge <= 249 &&
      beaconAge >= 0 &&
      beaconAge <= 1199;

  @override
  Future<bool> stopBeaconTargetStream() async {
    ++_beaconRevision;
    if (!_headTrackedActive) {
      _continuousBeaconStream = false;
      _beaconStreamRequested = false;
      return true;
    }
    final data = await _headTrackedPort.invoke('stop', const {});
    if (data['confirmed'] != true) {
      _uncertain = true;
      throw StateError('Native door audio stop not confirmed');
    }
    _headTrackedActive = false;
    _continuousBeaconStream = false;
    _beaconStreamRequested = false;
    if (!_closed) {
      _probe = {..._probe, ...data, 'phase': 'door-beacon-stopped', 'active': false};
    }
    return true;
  }

  void _event(Map<String, dynamic> data) {
    if (_closed || data['owner'] != _owner || data['id'] != _id) return;
    final pending = _playing;
    if (pending == null) return;
    _playing = null;
    final ok = data['completed'] == true;
    _probe = {
      ..._probe,
      ...data,
      'active': false,
      'phase': ok ? 'completed' : 'cancelled'
    };
    if (data['error'] == true) {
      _uncertain = true;
      pending
          .completeError(StateError('Native cue failure: ${data['reason']}'));
    } else {
      pending.complete(ok);
    }
  }

  void _retire() {
    _id++;
    final pending = _playing;
    _playing = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  @override
  Future<void> stop() {
    if (_disposing != null) return _disposing!;
    if (_stopBarrier != null) return _stopBarrier!;
    ++_beaconRevision;
    _retire();
    _uncertain = true;
    final operation = () async {
      final data = _headTrackedActive
          ? await _headTrackedPort.invoke('stop', const {})
          : await _port.invoke('stop', _args());
      if (data['confirmed'] != true) {
        throw StateError('Native stop not confirmed');
      }
      _headTrackedActive = false;
      _continuousBeaconStream = false;
      _beaconStreamRequested = false;
      _uncertain = false;
      if (!_closed) {
        _probe = {..._probe, ...data, 'phase': 'stopped', 'active': false};
      }
    }();
    _stopBarrier = operation;
    return operation.whenComplete(() {
      if (identical(_stopBarrier, operation)) _stopBarrier = null;
    });
  }

  @override
  Future<void> dispose() {
    if (_disposing != null) return _disposing!;
    _closed = true;
    ++_beaconRevision;
    _retire();
    _probe = {..._probe, 'phase': 'closing'};
    return _disposing = () async {
      // Listener retirement is immediate; its asynchronous cleanup must not
      // delay actual output release. _closed already rejects every late event.
      unawaited(_subscription.cancel().catchError((Object error) {
        debugPrint('Native audio event cleanup failure: ${error.runtimeType}');
      }));
      if (_headTrackedActive) {
        final stopped = await _headTrackedPort.invoke('stop', const {});
        if (stopped['confirmed'] != true) {
          throw StateError('HRTF dispose stop not confirmed');
        }
        _headTrackedActive = false;
        _continuousBeaconStream = false;
        _beaconStreamRequested = false;
      }
      final data = await _port.invoke('dispose', _args());
      if (data['confirmed'] != true) {
        throw StateError('Native dispose not confirmed');
      }
      _probe = {
        ..._probe,
        ...data,
        'phase': 'closed',
        'contextState': 'closed',
        'active': false
      };
    }();
  }

  @override
  Map<String, dynamic> snapshot() => Map<String, dynamic>.from(_probe);
}
