import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';

import '../services/speech_priority_coordinator.dart';
import '../features/hardware_bus/safety_integration_check_page.dart';

const mobiInk = Color(0xFF111111);
const mobiSurface = Colors.white;

ThemeData passengerTheme() {
  const panel = Color(0xFFF1F1F1);
  final scheme = ColorScheme.fromSeed(
    seedColor: mobiInk,
    dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
  ).copyWith(
    primary: mobiInk,
    onPrimary: mobiSurface,
    primaryContainer: panel,
    onPrimaryContainer: mobiInk,
    secondary: mobiInk,
    onSecondary: mobiSurface,
    secondaryContainer: panel,
    onSecondaryContainer: mobiInk,
    tertiary: mobiInk,
    onTertiary: mobiSurface,
    tertiaryContainer: panel,
    onTertiaryContainer: mobiInk,
    error: mobiInk,
    onError: mobiSurface,
    errorContainer: panel,
    onErrorContainer: mobiInk,
    surface: mobiSurface,
    onSurface: mobiInk,
    onSurfaceVariant: mobiInk,
    surfaceContainer: mobiSurface,
    surfaceContainerLow: mobiSurface,
    surfaceContainerHigh: panel,
    surfaceContainerHighest: panel,
    outline: mobiInk,
    outlineVariant: const Color(0xFF595959),
    surfaceTint: Colors.transparent,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: mobiSurface,
    appBarTheme: const AppBarTheme(
      backgroundColor: mobiSurface,
      foregroundColor: mobiInk,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: mobiInk,
        foregroundColor: mobiSurface,
        minimumSize: const Size(48, 56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: mobiInk,
        foregroundColor: mobiSurface,
        minimumSize: const Size(48, 56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: mobiSurface,
        foregroundColor: mobiInk,
        side: const BorderSide(color: mobiInk, width: 2),
        minimumSize: const Size(48, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ).copyWith(
        side: WidgetStateProperty.resolveWith((states) {
          return BorderSide(
            color: states.contains(WidgetState.disabled)
                ? const Color(0xFF767676)
                : mobiInk,
            width: 2,
          );
        }),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: mobiInk,
        minimumSize: const Size(48, 48),
      ),
    ),
    textTheme: base.textTheme
        .apply(bodyColor: mobiInk, displayColor: mobiInk)
        .copyWith(
          headlineMedium: base.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: mobiInk,
            height: 1.4,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: mobiInk,
          ),
        ),
  );
}

class PassengerLanding extends StatefulWidget {
  const PassengerLanding({
    super.key,
    required this.onOnline,
    this.speech,
    this.onSignOut,
    this.showSignOut = false,
  });
  final VoidCallback onOnline;
  final SpeechPriorityCoordinator? speech;
  final VoidCallback? onSignOut;
  final bool showSignOut;

  @override
  State<PassengerLanding> createState() => _PassengerLandingState();
}

enum _LandingDestination { routeInfo, vision, tests }

class _PassengerLandingState extends State<PassengerLanding> {
  final _speechOwner = Object();
  Timer? _tapWindow;
  _LandingDestination? _pending;
  int _speechRequest = 0;
  bool _opening = false;

  SpeechPriorityCoordinator get _speech =>
      widget.speech ?? sharedSpeechPriority;
  bool get _usesTapConfirmation =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _describe(String description, int request) async {
    try {
      await _speech.speakObservation(
        _speechOwner,
        description,
        () => mounted && request == _speechRequest && !_opening,
      );
    } catch (error) {
      debugPrint('MOBI home description: ${error.runtimeType}');
    }
  }

  Future<void> _stopDescription() async {
    try {
      await _speech.stopObservation(_speechOwner);
    } catch (error) {
      debugPrint('MOBI home description stop: ${error.runtimeType}');
    }
  }

  Future<void> _open(_LandingDestination destination) async {
    if (_opening) return;
    _opening = true;
    _pending = null;
    _tapWindow?.cancel();
    if (_speechRequest > 0) {
      _speechRequest++;
      unawaited(_stopDescription());
    }
    try {
      if (destination == _LandingDestination.routeInfo) {
        widget.onOnline();
      } else {
        await Navigator.of(context).pushNamed(
            destination == _LandingDestination.vision
                ? '/online-vision'
                : '/device-check');
      }
    } finally {
      _opening = false;
    }
  }

  void _tap(_LandingDestination destination, String description) {
    if (_opening) return;
    if (destination == _LandingDestination.vision ||
        !_usesTapConfirmation || _pending == destination) {
      unawaited(_open(destination));
      return;
    }
    _pending = destination;
    _tapWindow?.cancel();
    _tapWindow =
        Timer(const Duration(milliseconds: 500), () => _pending = null);
    unawaited(_describe(description, ++_speechRequest));
  }

  Future<void> _logout() async {
    if (_opening) return;
    _opening = true;
    _pending = null;
    _tapWindow?.cancel();
    _speechRequest++;
    unawaited(_stopDescription());
    try {
      if (widget.onSignOut != null) {
        widget.onSignOut!();
      } else {
        await AuthGate.signOut(context);
      }
    } finally {
      _opening = false;
    }
  }

  Widget _screenReaderButton(
    _LandingDestination destination,
    String label,
    String description,
    Widget child,
  ) =>
      Semantics(
        excludeSemantics: true,
        button: true,
        label: label,
        hint: description,
        onTap: () => unawaited(_open(destination)),
        child: child,
      );

  @override
  void dispose() {
    _tapWindow?.cancel();
    if (_speechRequest > 0) {
      _speechRequest++;
      unawaited(_stopDescription());
    }
    super.dispose();
  }

  static const _routeLabel = '노선 정보 검색';
  static const _routeDescription = '음성으로 버스 노선과 도착 정보를 물어보세요.';
  static const _visionLabel = '장애물 탐지';
  static const _visionDescription = '기사 승인 후 한 번 누르면 카메라와 장애물 탐지가 시작됩니다.';
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: const Text('MOBI.',
                style:
                    TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2)),
            actions: [
              if (widget.showSignOut || AuthGate.canSignOut(context))
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: mobiInk,
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: widget.showSignOut && widget.onSignOut == null
                      ? null
                      : () => unawaited(_logout()),
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('로그아웃'),
                ),
              const SizedBox(width: 8),
            ]),
        body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(24), children: [
          Text('무엇을 도와드릴까요?',
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 24),
          if (_usesTapConfirmation) ...[
            const Text('장애물 탐지는 한 번 누르면 시작합니다. 다른 메뉴는 한 번 누르면 설명을 듣고, 빠르게 두 번 누르면 열립니다.'),
            const SizedBox(height: 16),
          ],
          _screenReaderButton(
            _LandingDestination.routeInfo,
            _routeLabel,
            _routeDescription,
            FilledButton.icon(
              onPressed: () =>
                  _tap(_LandingDestination.routeInfo, _routeDescription),
              icon: const Icon(Icons.search_rounded),
              label: const Text(_routeLabel),
            ),
          ),
          const SizedBox(height: 8),
          const Text(_routeDescription),
          const SizedBox(height: 24),
          _screenReaderButton(
            _LandingDestination.vision,
            _visionLabel,
            _visionDescription,
            FilledButton.icon(
              onPressed: () =>
                  _tap(_LandingDestination.vision, _visionDescription),
              icon: const Icon(Icons.videocam_rounded),
              label: const Text(_visionLabel),
            ),
          ),
          const SizedBox(height: 8),
          const Text(_visionDescription),
          const SizedBox(height: 24),
          _screenReaderButton(
            _LandingDestination.tests,
            '테스트',
            '기능별 점검 화면을 엽니다. 모의 입력은 실제 안내와 구분됩니다.',
            FilledButton.icon(
              onPressed: () =>
                  _tap(_LandingDestination.tests, '기능별 점검 화면을 엽니다.'),
              icon: const Icon(Icons.checklist_rounded),
              label: const Text('테스트'),
            ),
          ),
        ])),
      );
}

class DeviceCheckPage extends StatelessWidget {
  const DeviceCheckPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('테스트')),
        body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(24), children: [
          const Text('각 테스트는 별도 화면에서 실행합니다. 모의 결과는 실제 검증과 구분합니다.'),
          const SizedBox(height: 16),
          OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const SafetyIntegrationCheckPage())),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('안전 중단·재개 통합 점검 (모의)')),
          for (final entry in const <String, (String, IconData)>{
            '/native-audio': ('음성·방향 확인 (Android)', Icons.volume_up_outlined),
            '/standalone-vision': ('서버 미연결 카메라·BLE 시연', Icons.videocam_outlined),
            '/hardware-bus': ('실기기 연동확인 · BLE/WT901/HRTF', Icons.bluetooth_connected),
            '/concurrent-hardware-test': ('동시 기기 테스트 (임시)', Icons.devices_other),
            '/tago-diagnostics': ('TAGO 실데이터 진단', Icons.directions_bus_outlined),
          }.entries)
            OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pushNamed(entry.key),
                icon: Icon(entry.value.$2),
                label: Text(entry.value.$1)),
        ])),
      );
}
