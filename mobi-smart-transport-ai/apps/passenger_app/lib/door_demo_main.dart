import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import 'src/features/hardware_bus/continuous_beacon_scanner.dart';
import 'src/features/hardware_bus/hardware_bus_page.dart' show beaconA;
import 'src/local_vision/native_local_vision_page.dart';
import 'src/services/audio_shutdown.dart';
import 'src/services/native_directional_cue_output.dart';
import 'src/services/spatial_verification_engine.dart';
import 'src/services/speech_priority_coordinator.dart';

void main() {
  if (!kDebugMode || !const bool.fromEnvironment('MOBI_DOOR_DEMO')) {
    throw StateError('Explicit debug door demo build required');
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: DoorDemoPage()));
}

class DoorDemoPage extends StatefulWidget {
  const DoorDemoPage({super.key});
  @override
  State<DoorDemoPage> createState() => _DoorDemoPageState();
}

class _DoorDemoPageState extends State<DoorDemoPage> {
  final _rssi = StreamController<int?>.broadcast(sync: true);
  late final _output = NativeDirectionalCueOutput();
  late final _engine = SpatialVerificationEngine(
      _output, FlutterSpeechEngine.platform(diagnostic: _output.recordTtsEvent),
      allowDirectTestCommands: false);
  late final _priority = SpeechPriorityCoordinator(_engine);
  StreamSubscription<BeaconSignal>? _scan;
  Timer? _expiry;
  int _generation = 0;
  bool _ready = false, _requesting = false;
  bool _directionOnly = false;
  String _message = '이어폰을 연결하고 카메라·주변 기기·정확한 위치 권한을 허용하세요.';
  String? _scanError;

  Future<void> _prepare() async {
    setState(() => _requesting = true);
    try {
      final state =
          await const MethodChannel('mobi.passenger/hardware-permissions')
              .invokeMapMethod<String, dynamic>('requestDoorDemo');
      if (!mounted) return;
      setState(() {
        _ready = state?['granted'] == true &&
            state?['cameraGranted'] == true &&
            state?['locationEnabled'] == true;
        if (!_ready) _message = '앱 권한과 휴대폰 위치 기능을 확인한 후 다시 눌러 주세요.';
      });
    } on PlatformException {
      if (mounted) setState(() => _message = '권한 확인 실패 · 다시 시도해 주세요.');
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _startScan() async {
    await _stopScan();
    if (!mounted) return;
    final generation = _generation;
    setState(() => _scanError = null);
    final scanner = ContinuousBeaconScanner(
        beaconIdResolver: (result) => result.device.remoteId.str.toUpperCase(),
        remoteIds: const [beaconA],
        scanTimeout: const Duration(hours: 1));
    void scanEnded() {
      if (!mounted || generation != _generation) return;
      _expiry?.cancel();
      _rssi.add(null);
      setState(() => _scanError = '비컨 스캔 종료 · 블루투스를 확인하고 카메라를 다시 시작하세요.');
    }

    _scan = scanner.scan(targetBeaconId: beaconA).listen((signal) {
      if (!mounted || generation != _generation || signal.beaconId != beaconA)
        return;
      final age = DateTime.now().difference(signal.lastDetectedAt);
      const timeout = Duration(seconds: 3);
      if (age.isNegative || age >= timeout) return;
      _expiry?.cancel();
      _rssi.add(signal.rssi);
      _expiry = Timer(timeout - age, () {
        if (mounted && generation == _generation) _rssi.add(null);
      });
    }, onError: (Object _) => scanEnded(), onDone: scanEnded);
  }

  Future<void> _stopScan() async {
    _generation++;
    _expiry?.cancel();
    if (!_rssi.isClosed) _rssi.add(null);
    final scan = _scan;
    _scan = null;
    await scan?.cancel();
  }

  @override
  void dispose() {
    unawaited(_stopScan());
    unawaited(_rssi.close());
    if (_ready) {
      unawaited(observeAudioCleanup(() async {
        try {
          await _engine.dispose();
        } finally {
          _priority.dispose();
        }
      }, channel: 'door demo', report: debugPrint));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
          appBar: AppBar(title: const Text('MOBI 내장 센서 시연')),
          body: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FilledButton(
                        onPressed: _requesting ? null : () => setState(() {
                          _directionOnly = true;
                          _ready = true;
                        }),
                        child: const Text('비컨 없이 내장 센서 방향 테스트')),
                    const Text('목표 비컨 A · $beaconA'),
                    Text(_message),
                    FilledButton(
                        onPressed: _requesting ? null : _prepare,
                        child: const Text('시연 준비')),
                  ])));
    }
    return Column(children: [
      if (_scanError != null)
        Material(child: SafeArea(bottom: false, child: Text(_scanError!))),
      Expanded(
          child: LocalVisionPage(
              doorDemo: true,
              phoneImu: true,
              directionOnly: _directionOnly,
              bundledModel: true,
              previewPriority: _priority,
              previewEngine: _engine,
              previewScope: 'door-demo',
              beaconRssiStream: _directionOnly ? null : _rssi.stream,
              beforeStart: _directionOnly ? null : _startScan,
              onStop: _directionOnly ? null : _stopScan)),
    ]);
  }
}
