import '../widgets/described_action.dart';
import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'frame_pump.dart';
import '../services/passenger_bus_guide.dart';
import 'vision_codec.dart';
import 'vision_worker.dart';
import '../widgets/vision_observation_panel.dart';
import '../services/v3_agent_api_client.dart';
import '../services/speech_priority_coordinator.dart';
import '../services/spatial_verification_engine.dart';
import '../services/vision_screen_audio.dart';
import '../widgets/vision_screen_audio_panel.dart';
import '../features/hardware_bus/wit_sensor_panel.dart';

const _cameraInk = Color(0xFF111111);
const _cameraPaper = Color(0xFFFFFFFF);

/// Optional transport and camera-screen information audio.
/// Safety output remains disabled. The shared engine is owned by Guidance.
class LocalVisionPage extends StatefulWidget {
  const LocalVisionPage(
      {super.key,
      this.producer,
      this.remoteApi,
      this.ownerUid,
      this.onEndSession,
      this.beforeStart,
      this.onResult,
      this.onStop,
      this.sessionCurrent,
      this.authChanges,
      this.remoteSessionId,
      this.bundledModel = false,
      this.autoStart = false,
      this.previewPriority,
      this.previewEngine,
      this.previewScope = 'camera-preview',
      this.busGuide,
      this.targetBeaconRssi,
      this.beaconRssiStream});
  final DartVisionProducerClient? producer;
  final V3AgentApiClient? remoteApi;
  final String? ownerUid;
  final Future<void> Function()? onEndSession;
  final Future<void> Function()? beforeStart;
  final Future<void> Function(LocalObservation)? onResult;
  final Future<void> Function()? onStop;
  final bool Function()? sessionCurrent;
  final Stream<String?>? authChanges;
  final String? remoteSessionId;
  final bool bundledModel;
  final bool autoStart;
  final SpeechPriorityCoordinator? previewPriority;
  final SpatialVerificationEngine? previewEngine;
  final String previewScope;
  final PassengerBusGuide? busGuide;
  final int? targetBeaconRssi;
  final Stream<int?>? beaconRssiStream;
  @override
  State<LocalVisionPage> createState() => _LocalVisionPageState();
}

class _LocalVisionPageState extends State<LocalVisionPage>
    with WidgetsBindingObserver {
  static const _hardwarePermissions =
      MethodChannel('mobi.passenger/hardware-permissions');
  static const _cameraHardware =
      MethodChannel('mobi.passenger/camera-hardware');
  StreamSubscription<String?>? _authSubscription;
  final _clock = Stopwatch()..start();
  final _runTime = Stopwatch();
  late final FramePump _pump;
  VisionScreenAudio? _previewAudio;
  StreamSubscription<int?>? _beaconRssiSubscription;
  final _history = DetectedFrameHistory();
  bool get _automaticPreviewAudio =>
      widget.remoteApi != null && widget.onResult != null;
  Uint8List? _model;
  VisionWorker? _worker;
  CameraController? _camera;
  CameraDescription? _description;
  bool _starting = false, _picking = false, _front = false;
  bool _disposing = false, _ending = false;
  bool _foreground = true;
  bool _autoStartAttempted = false;
  bool _modelPreparationFailed = false, _cameraPreparationFailed = false;
  int _generation = 0;
  Future<void>? _stopping;
  String _status = '통합 비전 모델 파일을 선택해 주세요';
  String? _serverCleanupIssue;

  double? _configuredCameraHorizontalFov() {
    final parsed = double.tryParse(
      const String.fromEnvironment('MOBI_CAMERA_HORIZONTAL_FOV_DEGREES'),
    );
    if (parsed != null && parsed.isFinite && parsed > 0 && parsed < 180) {
      return parsed;
    }
    return null;
  }

  Future<double> _resolveCameraHorizontalFov(
      CameraDescription description) async {
    final configured = _configuredCameraHorizontalFov();
    if (configured != null) return configured;
    if (Platform.isAndroid) {
      try {
        final info = await _cameraHardware.invokeMapMethod<String, dynamic>(
          'getCameraFov',
          {
            'cameraName': description.name,
            'lensDirection': description.lensDirection.name,
          },
        );
        final rawFov = info?['horizontalFovDegrees'];
        if (rawFov is num) {
          final fov = rawFov.toDouble();
          if (fov.isFinite && fov > 0 && fov < 180) {
            return fov;
          }
        }
      } catch (_) {/* fallback to smartphone default */}
    }
    return VisionScreenAudio.defaultSmartphoneHorizontalFovDegrees;
  }

  Future<bool> _ensureHeadTrackingReady() async {
    if (!Platform.isAndroid) return false;
    final state =
        await _hardwarePermissions.invokeMapMethod<String, dynamic>('request');
    return state?['granted'] == true && state?['locationEnabled'] == true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pump = FramePump(
        (frame) => _worker!.infer(frame), () => _clock.elapsedMicroseconds,
        onLocalResult: _onLocalResult,
        onResult: widget.onResult ?? widget.producer?.submit);
    _authSubscription = widget.authChanges?.listen((_) {
      if (widget.sessionCurrent?.call() == false) {
        _history.clear();
        unawaited(_stop(reason: '로그인 또는 안내 세션이 종료되었습니다', failed: true));
      }
    }, onError: (Object _) {
      _history.clear();
      unawaited(_stop(reason: '로그인 상태를 확인할 수 없어 카메라를 중지했습니다', failed: true));
    });
    if (widget.previewPriority != null && widget.previewEngine != null) {
      _previewAudio = VisionScreenAudio(
          priority: widget.previewPriority!,
          engine: widget.previewEngine!,
          sessionGeneration: widget.previewScope,
          arrivalBusNumber: widget.busGuide?.visualOnly == true
              ? null
              : () => _front ? null : widget.busGuide?.cameraBus,
          externalDirection: widget.busGuide?.visualOnly == true,
          horizontalFovDegrees: _configuredCameraHorizontalFov() ??
              VisionScreenAudio.defaultSmartphoneHorizontalFovDegrees,
          confirmationFrames: _automaticPreviewAudio ? 1 : 3,
          sceneMode: false,
          pingOnly: false,
          minimumInterval: const Duration(seconds: 8),
          requireDoorInBus: false,
          prioritizeByDistance: true,
          ccwPositiveYaw: true,
          initialBeaconRssi: widget.targetBeaconRssi,
          isCurrent: () =>
              mounted &&
              !_disposing &&
              _pump.active &&
              !_pump.lost &&
              widget.sessionCurrent?.call() != false);
    }
    _previewAudio?.addListener(_syncGuide);
    _beaconRssiSubscription = widget.beaconRssiStream?.listen((rssi) {
      _previewAudio?.updateBeaconRssi(rssi);
    });
    _pump.addListener(_changed);
    if (widget.bundledModel) unawaited(_loadBundledModel());
  }

  void _changed() {
    if (!mounted || _disposing) return;
    setState(() {});
    if (_pump.error != null && _camera != null) {
      unawaited(_stop(reason: _pump.error!, failed: true));
    }
  }

  void _syncGuide() {
    final guide = widget.busGuide;
    if (guide?.visualOnly == true) {
      if (guide!.spokenClass != _previewAudio?.spokenObjectClass)
        guide.clearDoor();
      guide.spokenClass = _previewAudio?.spokenObjectClass;
    }
    guide?.previewBusy(
      _previewAudio?.busy == true,
      arrivalAnnounced: _previewAudio?.arrivalAnnounced == true,
    );
  }

  void _onLocalResult(LocalObservation item, Map<String, Object?> result) {
    if (!mounted || _disposing || widget.sessionCurrent?.call() == false) {
      return;
    }
    _history.record(item);
    final guide = widget.busGuide;
    final fov = _previewAudio?.horizontalFovDegrees;
    if (guide != null &&
        !_front &&
        fov != null &&
        (guide.visualOnly ||
            _previewAudio?.arrivalAnnounced == true &&
                guide.cameraBus != null)) {
      guide.frame(result, item.frame.receivedAt, fov);
    }
    _previewAudio?.observe(result,
        receivedAt: item.frame.receivedAt,
        inferenceMs: item.inferenceMs,
        processingMs: item.processingMs,
        age: Duration(
            microseconds:
                _clock.elapsedMicroseconds - item.frame.receivedMicros));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android's first camera permission dialog temporarily makes the app
    // inactive. A real background transition (hidden/paused) still stops it.
    if (state == AppLifecycleState.inactive && _starting) return;
    _foreground = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) {
      unawaited(_stop(reason: '앱 비활성화 · 카메라 중지됨'));
    }
  }

  Future<void> _loadBundledModel() async {
    final preparationGeneration = _generation;
    setState(() {
      _picking = true;
      _status = widget.autoStart ? '장애물 탐지를 준비하고 있습니다.' : '통합 비전 v4 모델 준비 중';
    });
    try {
      final data = await rootBundle.load(
          'assets/models/yolo11n_unified_bus_obstacle_stop_v4_float32.tflite');
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await compute(verifyModel, bytes);
      if (mounted && !_disposing) {
        setState(() {
          _model = bytes;
          _modelPreparationFailed = false;
          _status = widget.autoStart
              ? '카메라를 시작하고 있습니다.'
              : '통합 비전 v4 모델 준비 완료 · 카메라 시작을 눌러 주세요';
        });
      }
    } catch (_) {
      if (mounted && !_disposing) {
        setState(() {
          _modelPreparationFailed = true;
          _status = '모델 준비 실패 · 다시 준비해 주세요';
        });
      }
    } finally {
      if (mounted && !_disposing) setState(() => _picking = false);
    }
    if (widget.autoStart &&
        _model != null &&
        mounted &&
        !_disposing &&
        (!_foreground ||
            preparationGeneration != _generation ||
            widget.sessionCurrent?.call() == false)) {
      setState(() {
        _autoStartAttempted = true;
        _status = '시작이 중단되었습니다. 승인 상태를 확인한 뒤 탐지 다시 시작을 눌러 주세요.';
      });
      return;
    }
    if (widget.autoStart &&
        _model != null &&
        !_modelPreparationFailed &&
        mounted &&
        !_disposing &&
        _foreground &&
        preparationGeneration == _generation &&
        widget.sessionCurrent?.call() != false) {
      _autoStartAttempted = true;
      await _start();
    }
  }

  Future<void> _chooseModel() async {
    if (_starting || _camera != null || _picking) return;
    setState(() => _picking = true);
    try {
      final file = await FilePicker.pickFile(
          type: FileType.custom, allowedExtensions: ['tflite']);
      if (file == null) return;
      final length = await file.length();
      if (length == null || length <= 0 || length > 16 * 1024 * 1024) {
        throw const FormatException('모델 파일 크기가 잘못됐습니다.');
      }
      final bytes = await file.readAsBytes();
      await compute(verifyModel, bytes);
      if (mounted) {
        setState(() {
          _model = bytes;
          _modelPreparationFailed = false;
          _status = '비전 모델 SHA256 확인 완료';
        });
      }
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          _model = null;
          _modelPreparationFailed = true;
          _status = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _modelPreparationFailed = true;
          _status = '모델 파일을 읽을 수 없습니다';
        });
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _start() async {
    if (!Platform.isAndroid || _model == null || _starting || _camera != null) {
      return;
    }
    await _stopping;
    if (!mounted || _disposing || !_foreground || _starting || _camera != null)
      return;
    final generation = ++_generation;
    setState(() {
      _starting = true;
      _serverCleanupIssue = null;
      _status = '모델·카메라 준비 중';
    });
    try {
      if (widget.sessionCurrent?.call() == false) {
        throw StateError('Guidance session ended');
      }
      await widget.beforeStart?.call();
      if (!mounted ||
          _disposing ||
          generation != _generation ||
          widget.sessionCurrent?.call() == false) {
        await widget.onStop?.call();
        return;
      }
      await widget.producer?.retryPending(discardExpired: true);
      final worker = await VisionWorker.open(_model!);
      if (!_startCurrent(generation)) {
        await worker.close();
        await _stop();
        return;
      }
      _worker = worker;
      final devices = await availableCameras();
      if (!_startCurrent(generation)) {
        await _stop();
        return;
      }
      if (devices.isEmpty) throw CameraException('NoCamera', '');
      final wanted =
          _front ? CameraLensDirection.front : CameraLensDirection.back;
      final matches = devices.where((d) => d.lensDirection == wanted);
      if (matches.isEmpty) throw CameraException('LensUnavailable', '');
      _description = matches.first;
      final fov = await _resolveCameraHorizontalFov(_description!);
      if (!_startCurrent(generation)) {
        await worker.close();
        if (_worker == worker) _worker = null;
        await _stop();
        return;
      }
      _previewAudio?.setHorizontalFovDegrees(fov);
      final camera = CameraController(_description!, ResolutionPreset.medium,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
      _camera = camera;
      camera.addListener(() {
        if (_camera == camera && camera.value.hasError) {
          unawaited(_stop(reason: '카메라 연결이 소실되었습니다', failed: true));
        }
      });
      await camera.initialize();
      if (!_startCurrent(generation)) {
        await _stop();
        return;
      }
      _pump.start();
      widget.busGuide?.mute(false);
      if (_automaticPreviewAudio) _previewAudio?.setEnabled(true);
      _runTime
        ..reset()
        ..start();
      await camera.startImageStream((image) => _onFrame(image, generation));
      if (mounted && generation == _generation) {
        setState(() {
          _modelPreparationFailed = false;
          _cameraPreparationFailed = false;
          _status = '휴대폰 내부 카메라 관찰 중';
        });
      }
    } on CameraException catch (e) {
      final text = switch (e.code) {
        'CameraAccessDenied' ||
        'CameraAccessDeniedWithoutPrompt' =>
          '카메라 권한이 거부되었습니다. 앱 설정에서 허용해 주세요',
        'CameraAccessRestricted' => '기기 정책으로 카메라 접근이 제한되었습니다',
        'NoCamera' => '사용 가능한 카메라 장치가 없습니다',
        'LensUnavailable' => '선택한 전면/후면 카메라가 없습니다',
        _ => '카메라 초기화 실패 · 기기 및 카메라 사용 여부를 확인해 주세요',
      };
      await _stop(reason: text, failed: true);
    } on VisionLeaseException catch (error) {
      await _stop(
          reason: '서버 카메라 연결 실패 (${error.diagnosticCode})', failed: true);
    } on VisionProducerException catch (e) {
      await _stop(reason: e.message, failed: true);
    } catch (_) {
      await _stop(
          reason: widget.autoStart
              ? '탐지를 시작하지 못했습니다. 탐지 다시 시작을 눌러 주세요.'
              : '모델 또는 카메라를 시작하지 못했습니다. 모델 다시 준비 후 카메라 시작을 눌러 주세요. 반복되면 앱을 다시 실행해 주세요',
          failed: true);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  bool _startCurrent(int generation) =>
      mounted &&
      !_disposing &&
      _foreground &&
      generation == _generation &&
      widget.sessionCurrent?.call() != false;

  void _onFrame(CameraImage image, int generation) {
    if (_disposing || generation != _generation) return;
    if (widget.sessionCurrent?.call() == false) {
      _history.clear();
      unawaited(_stop(reason: '안내 세션 종료 · 카메라 중지', failed: true));
      return;
    }
    final camera = _camera, description = _description;
    if (!_pump.active || camera == null || description == null) return;
    final degrees = switch (camera.value.deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    final format =
        image.format.group == ImageFormatGroup.nv21 || image.format.raw == 17
            ? 'nv21'
            : image.format.group == ImageFormatGroup.yuv420
                ? 'yuv420'
                : image.format.group == ImageFormatGroup.bgra8888
                    ? 'bgra8888'
                    : 'unsupported';
    _pump.submit(VisionFrame(
        width: image.width,
        height: image.height,
        format: format,
        planes: image.planes
            .map((p) => FramePlane(Uint8List.fromList(p.bytes), p.bytesPerRow,
                p.bytesPerPixel ?? 1))
            .toList(),
        rotation: frameRotation(description.sensorOrientation, degrees,
            description.lensDirection == CameraLensDirection.front),
        mirror: description.lensDirection == CameraLensDirection.front,
        receivedAt: DateTime.now().toUtc(),
        receivedMicros: _clock.elapsedMicroseconds));
  }

  Future<void> _stop({String reason = '카메라 중지됨', bool failed = false}) {
    if (widget.autoStart) _autoStartAttempted = true;
    DescribedAction.cancelDescriptions();
    widget.busGuide?.clearDoor();
    final previewStop = _previewAudio?.stop(notify: !_disposing);
    if (_stopping != null) return _stopping!;
    _generation++;
    final camera = _camera, worker = _worker;
    _camera = null;
    _worker = null;
    _runTime.stop();
    widget.producer?.cancel();
    final idle = _pump.stop();
    if (mounted && !_disposing) {
      setState(() {
        if (failed || !_cameraPreparationFailed) _status = reason;
        if (failed) _cameraPreparationFailed = true;
      });
    }
    final future = () async {
      try {
        if (camera?.value.isStreamingImages == true) {
          await camera!.stopImageStream();
        }
      } catch (_) {/* device already disconnected */}
      try {
        await camera?.dispose();
      } catch (_) {/* already disconnected */}
      await idle;
      await worker?.close();
      await previewStop;
      try {
        await widget.onStop?.call();
      } on VisionLeaseException catch (error) {
        if (mounted && !_disposing) {
          setState(() {
            _serverCleanupIssue = '서버 연결 해제 확인 불가 (${error.diagnosticCode})';
          });
        }
      }
    }();
    _stopping = future;
    return future.whenComplete(() {
      _stopping = null;
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant LocalVisionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.targetBeaconRssi != oldWidget.targetBeaconRssi) {
      _previewAudio?.updateBeaconRssi(widget.targetBeaconRssi);
    }
    if (widget.beaconRssiStream != oldWidget.beaconRssiStream) {
      unawaited(_beaconRssiSubscription?.cancel());
      _beaconRssiSubscription = widget.beaconRssiStream?.listen((rssi) {
        _previewAudio?.updateBeaconRssi(rssi);
      });
    }
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_authSubscription?.cancel());
    unawaited(_beaconRssiSubscription?.cancel());
    _pump.removeListener(_changed);
    _history.dispose();
    _previewAudio?.removeListener(_syncGuide);
    widget.busGuide?.previewBusy(false);
    _previewAudio?.dispose(); // Retire UI callbacks before any lease release.
    unawaited(_stop());
    _pump.dispose();
    _model = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const Scaffold(
          body: Center(child: Text('로컬 카메라 추론은 Android에서 지원합니다.')));
    }
    final item = _pump.observation;
    final busy = _starting || _picking || _stopping != null || _ending;
    final camera = _camera?.value;
    final lostFrames = _pump.active && _pump.lost;
    // A verified model is ready for Start before the camera is opened.
    // Once opened, preparation also requires a healthy camera stream.
    final cameraReady = _model != null &&
        !_modelPreparationFailed &&
        !_cameraPreparationFailed &&
        !busy &&
        !lostFrames &&
        (camera == null ||
            (camera.isInitialized &&
                camera.isStreamingImages &&
                !camera.hasError &&
                _pump.active));
    return ActionSpeechScope(
        speech: widget.previewPriority ?? sharedSpeechPriority,
        child: Scaffold(
            appBar: AppBar(title: const Text('카메라 인식')),
            bottomNavigationBar: SafeArea(
                child: Container(
                    decoration: const BoxDecoration(
                      color: _cameraPaper,
                      border: Border(top: BorderSide(color: _cameraInk)),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Wrap(spacing: 12, runSpacing: 8, children: [
                      if (_previewAudio != null)
                        FilledButton.icon(
                            onPressed: () {
                              DescribedAction.cancelDescriptions();
                              widget.busGuide?.mute(true);
                              _previewAudio!.stop();
                            },
                            icon: const Icon(Icons.volume_off_outlined),
                            label: const Text('음성 중지')),
                      OutlinedButton.icon(
                          onPressed: _camera == null && !_starting
                              ? null
                              : () {
                                  DescribedAction.cancelDescriptions();
                                  _stop();
                                },
                          icon: const Icon(Icons.videocam_off_outlined),
                          label: const Text('카메라 중지')),
                    ]))),
            body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (busy)
                        const LinearProgressIndicator(
                            semanticsLabel: '카메라 작업 처리 중')
                      else
                        Semantics(
                          liveRegion: true,
                          child: _CameraInformationPanel(
                            child: Text(
                              cameraStatusLabel(
                                  ready: cameraReady,
                                  cleanupIssue: _serverCleanupIssue),
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(color: _cameraInk),
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      CameraObservationSurface(
                        livePreview: _camera?.value.isInitialized == true
                            ? AspectRatio(
                                aspectRatio: _camera!.value.aspectRatio,
                                child: CameraPreview(_camera!))
                            : null,
                      ),
                      const SizedBox(height: 12),
                      DetectedFrameReviewButton(history: _history),
                      if (item != null && item.boxes.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _CameraInformationPanel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('현재 인식 결과',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                              for (final box in item.boxes.take(3))
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 6),
                                  child: Text(
                                    '${visionClassNames[box.classId] ?? box.classId} · ${(box.confidence * 100).round()}%',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(color: _cameraInk),
                                  ),
                                ),
                              if (item.boxes.length > 3)
                                Text(
                                    '외 ${item.boxes.length - 3}개 · 검출 이미지에서 확인'),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (widget.remoteApi == null &&
                          widget.producer == null &&
                          widget.onResult == null)
                        const Text('휴대폰 내부 관찰 · 서버로 전송하지 않습니다.'),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        if (!widget.autoStart || _modelPreparationFailed)
                          DescribedAction.button(
                              label: widget.autoStart
                                  ? '다시 시도'
                                  : widget.bundledModel
                                      ? '모델 다시 준비'
                                      : 'TFLite 모델 선택',
                              description: '객체 인식에 사용할 모델을 준비합니다.',
                              immediate: widget.autoStart,
                              child: OutlinedButton.icon(
                                  onPressed: busy || _camera != null
                                      ? null
                                      : widget.bundledModel
                                          ? _loadBundledModel
                                          : _chooseModel,
                                  icon: Icon(widget.bundledModel
                                      ? Icons.refresh
                                      : Icons.folder_open_outlined),
                                  label: Text(widget.autoStart
                                      ? '다시 시도'
                                      : widget.bundledModel
                                          ? '모델 다시 준비'
                                          : 'TFLite 모델 선택'))),
                        if (!widget.autoStart ||
                            _autoStartAttempted && !busy && _camera == null)
                          DescribedAction.button(
                              label: widget.autoStart ? '탐지 다시 시작' : '카메라 시작',
                              description: '카메라 촬영과 객체 인식을 시작합니다.',
                              immediate: widget.autoStart,
                              child: FilledButton.icon(
                                  onPressed:
                                      busy || _model == null || _camera != null
                                          ? null
                                          : _start,
                                  icon: const Icon(Icons.videocam_outlined),
                                  label: Text(widget.autoStart
                                      ? '탐지 다시 시작'
                                      : '카메라 시작'))),
                      ]),
                      if (_previewAudio != null)
                        VisionScreenAudioPanel(
                            audio: _previewAudio!,
                            cameraActive: _pump.active,
                            showStopButton: false,
                            diagnostics: widget.remoteApi == null,
                            automaticallyEnabled: _automaticPreviewAudio),
                      if (_previewAudio != null && widget.remoteApi == null)
                        ExpansionTile(
                            title: const Text('WT901 Head Tracking (기본 OFF)'),
                            subtitle:
                                const Text('센서 연결·정면 보정·검증된 카메라 화각이 모두 필요'),
                            maintainState: true,
                            children: [
                              WitSensorPanel(
                                  stateOnly: true,
                                  ensureReady: _ensureHeadTrackingReady),
                            ]),
                      if (widget.onEndSession != null)
                        OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () async {
                                    setState(() => _ending = true);
                                    await _stop(reason: '세션 종료 · 카메라/전송 중지');
                                    try {
                                      await widget.onEndSession!();
                                    } finally {
                                      if (mounted)
                                        setState(() => _ending = false);
                                    }
                                  },
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('세션 종료 · 카메라/전송 중지')),
                      if (!busy &&
                          (!cameraReady || _serverCleanupIssue != null))
                        ExpansionTile(
                          title: const Text('카메라 상태 상세'),
                          children: [
                            ListTile(
                              title: Text(lostFrames
                                  ? '프레임 수신 소실 또는 지연 · 카메라를 중지한 뒤 다시 시작해 주세요'
                                  : _status),
                            ),
                            if (_serverCleanupIssue case final issue?)
                              ListTile(title: Text('종료 처리: $issue')),
                          ],
                        ),
                      if (_worker != null && widget.remoteApi == null)
                        Text(
                            'TFLite 로드 ${_worker!.loadMs.toStringAsFixed(1)}ms · warm-up ${_worker!.warmUpMs.toStringAsFixed(1)}ms'),
                      // The normal passenger screen uses the live preview and audio;
                      // keep the server observation card only in the diagnostic flow.
                      if (!_automaticPreviewAudio &&
                          widget.remoteApi != null &&
                          (widget.producer != null ||
                              widget.remoteSessionId != null) &&
                          _pump.active &&
                          _pump.error == null &&
                          _pump.processed > 0)
                        VisionObservationPanel(
                            key: ValueKey(_generation),
                            sessionId: widget.remoteSessionId ??
                                widget.producer!.sessionId,
                            ownerUid: widget.ownerUid,
                            fetch: widget.remoteApi!.fetchVisionObservations,
                            hideSpeechControls: true),
                      if (widget.remoteApi == null)
                        ExpansionTile(
                            title: const Text('인식 상세 정보'),
                            maintainState: true,
                            children: [
                              if (item != null)
                                VisionObservationPanel.localCamera(item),
                              Text(
                                  '처리 ${_pump.processed} · 최신 프레임 대체 ${_pump.replaced} · 만료 폐기 ${_pump.expired} · 중복/역순 거부 ${_pump.rejected}'),
                              Text(
                                  '처리 FPS ${_runTime.elapsedMilliseconds == 0 ? '0' : (_pump.processed * 1000 / _runTime.elapsedMilliseconds).toStringAsFixed(1)} · 앱 RSS ${(ProcessInfo.currentRss / 1048576).toStringAsFixed(1)}MiB'),
                              const Text('실기기 성능·발열·bbox 정합성 확인이 필요합니다.'),
                            ]),
                      SwitchListTile(
                          secondary: const Icon(Icons.cameraswitch_outlined),
                          title: const Text('전면 카메라 사용'),
                          value: _front,
                          onChanged: busy || _camera != null
                              ? null
                              : (v) => setState(() => _front = v)),
                    ]))));
  }
}

String cameraStatusLabel({required bool ready, required String? cleanupIssue}) {
  if (!ready) return '카메라 상태: 오류';
  if (cleanupIssue != null) return '카메라 중지됨 · 서버 해제 미확인';
  return '카메라 상태: 준비 완료';
}

class _CameraInformationPanel extends StatelessWidget {
  const _CameraInformationPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: _cameraPaper,
          border: Border.all(color: _cameraInk),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: _cameraInk),
            child: child,
          ),
        ),
      );
}

class _BoxPainter extends CustomPainter {
  _BoxPainter(this.boxes);
  final List<LocalBox> boxes;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const labelPadding = EdgeInsets.symmetric(horizontal: 4, vertical: 2);
    final outerStroke = Paint()
      ..color = _cameraInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    final innerStroke = Paint()
      ..color = _cameraPaper
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final labelBackground = Paint()..color = _cameraInk;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final b in boxes) {
      final rect = Rect.fromLTWH(b.x * size.width, b.y * size.height,
          b.w * size.width, b.h * size.height);
      canvas.drawRect(rect, outerStroke);
      canvas.drawRect(rect, innerStroke);
    }
    // Paint opaque class labels above every border, never directly on footage.
    for (final b in boxes) {
      final label = TextPainter(
        text: TextSpan(
          text: '${b.classId} ${(b.confidence * 100).round()}%',
          style: const TextStyle(
            color: _cameraPaper,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(
          maxWidth: (size.width - labelPadding.horizontal)
              .clamp(0.0, size.width)
              .toDouble());
      final labelWidth = label.width + labelPadding.horizontal;
      final labelHeight = label.height + labelPadding.vertical;
      final left = (b.x * size.width)
          .clamp(0.0, (size.width - labelWidth).clamp(0.0, size.width))
          .toDouble();
      final top = (b.y * size.height)
          .clamp(0.0, (size.height - labelHeight).clamp(0.0, size.height))
          .toDouble();
      canvas.drawRect(
          Rect.fromLTWH(left, top, labelWidth, labelHeight), labelBackground);
      label.paint(
          canvas, Offset(left + labelPadding.left, top + labelPadding.top));
      label.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BoxPainter oldDelegate) => oldDelegate.boxes != boxes;
}

/// Fixed live surface. Detection images are rendered only in the history page.
class CameraObservationSurface extends StatelessWidget {
  const CameraObservationSurface({super.key, this.livePreview});
  final Widget? livePreview;
  @override
  Widget build(BuildContext context) => SizedBox(
        key: const ValueKey('live-camera-surface'),
        height: 300,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _cameraPaper,
            border: Border.all(color: _cameraInk, width: 2),
          ),
          child: livePreview == null
              ? const Center(
                  child: Text('카메라 시작을 기다리고 있습니다',
                      style: TextStyle(color: _cameraInk)))
              : Center(child: livePreview),
        ),
      );
}

typedef DetectedFrame = ({
  String id,
  DateTime receivedAt,
  Uint8List jpeg,
  List<LocalBox> boxes,
  int width,
  int height,
});

/// Keep compressed images and boxes in camera-screen memory, without raw planes.
class DetectedFrameHistory extends ValueNotifier<List<DetectedFrame>> {
  DetectedFrameHistory() : super(const []);

  void record(LocalObservation item) {
    if (item.boxes.isEmpty || item.jpeg.isEmpty) return;
    final id = item.frame.frameId;
    if (value.isNotEmpty && value.first.id == id) return;
    value = List.unmodifiable([
      (
        id: id,
        receivedAt: item.frame.receivedAt,
        jpeg: item.jpeg,
        boxes: List<LocalBox>.unmodifiable(item.boxes),
        width: item.width,
        height: item.height,
      ),
      ...value.take(23),
    ]);
  }

  void clear() => value = const [];
}

class DetectedFrameReviewButton extends StatelessWidget {
  const DetectedFrameReviewButton({super.key, required this.history});

  final DetectedFrameHistory history;

  @override
  Widget build(BuildContext context) => DescribedAction.button(
        label: '인식 프레임 확인',
        description: '객체가 검출된 프레임을 별도 화면에서 확인합니다.',
        immediate: false,
        child: OutlinedButton.icon(
          onPressed: () {
            final page = _DetectedFramesPage(history);
            Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => page));
          },
          icon: const Icon(Icons.image_search_outlined),
          label: const Text('인식 프레임 확인'),
        ),
      );
}

class _DetectedFramesPage extends StatelessWidget {
  _DetectedFramesPage(this.history) : frames = history.value;
  final DetectedFrameHistory history;
  final List<DetectedFrame> frames;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('인식 프레임 확인')),
        body: ValueListenableBuilder(
          valueListenable: history,
          builder: (context, current, child) =>
              frames.isEmpty || current.isEmpty
                  ? const Center(child: Text('저장된 검출 프레임이 없습니다.'))
                  : child!,
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: frames.length,
            itemBuilder: (context, index) {
              final frame = frames[index];
              return Padding(
                key: ValueKey(frame.id),
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CameraInformationPanel(
                      child: Text('수신 시각: ${frame.receivedAt.toLocal()}'),
                    ),
                    AspectRatio(
                      aspectRatio: frame.width / frame.height,
                      child: Stack(fit: StackFit.expand, children: [
                        Image.memory(frame.jpeg, fit: BoxFit.fill),
                        CustomPaint(painter: _BoxPainter(frame.boxes)),
                      ]),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
}
