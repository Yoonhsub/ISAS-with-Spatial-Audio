import '../../widgets/described_action.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import 'live_caption_controller.dart';
import 'live_caption_overlay.dart';
import 'live_voice_controller.dart';
import 'voice_turn_state.dart';

/// 전체 화면 Live 음성 대화 페이지.
/// 불투명한 흑백 화면 + 마이크 버튼 기반 turn-taking + 5줄 rolling 자막.
class LiveVoicePage extends StatefulWidget {
  const LiveVoicePage({
    super.key,
    required this.agentName,
    required this.processor,
    required this.speak,
    required this.stopAudio,
    required this.onExit,
  });

  final String agentName;
  final LiveUtteranceProcessor processor;
  final LiveSpeak speak;

  /// 진행 중인 Live TTS 재생/WebSocket을 즉시 중단한다(X·종료 시).
  final Future<void> Function() stopAudio;

  /// Live 세션 종료 시 호출. [navigated]이 true면 길 안내 동의로 인한 전환.
  final void Function(
    List<LiveCaptionLine> sessionLog, {
    required bool navigated,
  }) onExit;

  @override
  State<LiveVoicePage> createState() => _LiveVoicePageState();
}

class _LiveVoicePageState extends State<LiveVoicePage> {
  late final LiveCaptionController _captions;
  late final LiveVoiceController _controller;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    _captions = LiveCaptionController();
    _controller = LiveVoiceController(
      captions: _captions,
      processor: widget.processor,
      speak: widget.speak,
      stopAudio: widget.stopAudio,
      onNavigate: () => _exit(navigated: true),
      onEnd: () => _exit(navigated: false),
    );
    // iOS/인앱 브라우저는 AudioContext 시작이 사용자 제스처에서 멀어질수록
    // 조용히 suspend될 수 있어, route build 직후 곧바로 시작한다.
    unawaited(_controller.start());
  }

  Future<void> _exit({required bool navigated}) async {
    if (_exiting) return;
    _exiting = true;
    DescribedAction.cancelDescriptions();
    // 1) 남은 partial을 final로 정리해 로그 보존.
    _captions.flushTemporaryToSessionLog();
    final log = _captions.sessionLog;
    // 2) 진행 중인 Live TTS 재생/WebSocket 즉시 중단 + 마이크/STT/타이머 정리.
    //    정리가 길어지거나 멈춰도(iOS 오디오 컨텍스트/WS close 지연) 화면 전환이
    //    막히지 않도록 타임아웃을 둔다. (수십초 멈춰 X를 눌러야 했던 문제 방지)
    //    단, 길 안내 전환에서는 마지막 안내 음성을 끝까지 들려야 하므로 TTS는
    //    계속 재생하게 두고 마이크/STT만 정리한다.
    if (!navigated) {
      try {
        await widget.stopAudio().timeout(const Duration(milliseconds: 700));
      } catch (_) {}
    }
    try {
      await _controller.stop().timeout(const Duration(milliseconds: 700));
    } catch (_) {}
    // 3) 화면 임시 자막 제거.
    _captions.clearTemporary();
    // 4) 로그 전달(부모가 통합 대화 로그에 저장) + 네비 전환 여부 통지.
    widget.onExit(log, navigated: navigated);
    // 5) Live 페이지 종료.
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _captions.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit(navigated: false);
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('음성으로 질문하기',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      AnimatedBuilder(
                        animation: Listenable.merge([
                          _controller.state,
                          _controller.microphoneActive,
                          _controller.microphoneFinishing,
                          _controller.microphoneUnavailable,
                        ]),
                        builder: (context, _) => LiveMicrophoneStatus(
                          state: _controller.state.value,
                          active: _controller.microphoneActive.value,
                          finishing: _controller.microphoneFinishing.value,
                          unavailable: _controller.microphoneUnavailable.value,
                        ),
                      ),
                      const SizedBox(height: 24),
                      LiveCaptionOverlay(
                          controller: _captions, agentName: widget.agentName),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                child: ValueListenableBuilder<VoiceTurnState>(
                  valueListenable: _controller.state,
                  builder: (context, state, _) => _BottomControls(
                    blocked: state == VoiceTurnState.thinking,
                    onMicTap: () {
                      DescribedAction.cancelDescriptions();
                      _controller.handleMicTap();
                    },
                    onClose: () => _exit(navigated: false),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows actual recognizer readiness, not merely the desired listening state.
class LiveMicrophoneStatus extends StatelessWidget {
  const LiveMicrophoneStatus(
      {super.key,
      required this.state,
      required this.active,
      this.finishing = false,
      this.unavailable = false});
  final VoiceTurnState state;
  final bool active;
  final bool unavailable;
  final bool finishing;

  @override
  Widget build(BuildContext context) {
    final listening = state == VoiceTurnState.listening && active;
    final (title, message, icon) = switch (state) {
      VoiceTurnState.thinking => (
          '답변 준비 중',
          '음성 입력이 잠시 멈춰 있습니다.',
          Icons.hourglass_top_rounded
        ),
      VoiceTurnState.speaking => (
          '답변 읽는 중',
          '다시 말씀하려면 아래 마이크 버튼을 눌러 주세요.',
          Icons.volume_up_rounded
        ),
      _ when unavailable => (
          '마이크 확인 필요',
          '마이크 권한을 확인한 뒤 아래 버튼으로 다시 시작해 주세요.',
          Icons.mic_off_rounded
        ),
      VoiceTurnState.listening when listening => (
          '듣는 중',
          '마이크가 켜져 있습니다. 지금 말씀해 주세요.',
          Icons.mic_rounded
        ),
      VoiceTurnState.listening when finishing => (
          '음성 확인 중',
          '말씀하신 내용을 확인하고 있습니다.',
          Icons.hourglass_top_rounded
        ),
      VoiceTurnState.listening => (
          '마이크 연결 중',
          '음성 입력을 준비하고 있습니다.',
          Icons.mic_none_rounded
        ),
      VoiceTurnState.idle => (
          '음성 입력 대기',
          '다음 답변을 하려면 아래 마이크 버튼을 눌러 주세요.',
          Icons.mic_off_rounded
        ),
    };
    final foreground = listening ? Colors.white : const Color(0xFF111111);
    return Semantics(
      liveRegion: true,
      label: '$title. $message',
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: listening ? const Color(0xFF111111) : Colors.white,
          border: Border.all(color: const Color(0xFF111111), width: 3),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: foreground, size: 48),
            const SizedBox(height: 8),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: foreground,
                    fontSize: 28,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: foreground, fontSize: 17, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

class _BottomControls extends StatelessWidget {
  const _BottomControls({
    required this.onMicTap,
    required this.onClose,
    required this.blocked,
  });
  final bool blocked;

  final VoidCallback onMicTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '“○○ 가고싶은데 몇 번 버스 타?”라고 질문해 주세요.',
          style: TextStyle(color: Color(0xFF111111), fontSize: 12),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DescribedAction(
              label: '음성 질문 시작',
              description: '마이크를 켜서 음성으로 질문합니다.',
              immediate: true,
              onActivate: blocked ? null : onMicTap,
              child: _RoundButton(
                icon: Icons.mic,
                background: const Color(0xFF111111),
                onTap: blocked ? null : onMicTap,
              ),
            ),
            const SizedBox(width: 28),
            _RoundButton(
              icon: Icons.close,
              background: const Color(0xFF111111),
              size: 64,
              onTap: onClose,
            ),
          ],
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.background,
    required this.onTap,
    this.size = 56,
  });

  final IconData icon;
  final Color background;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onTap == null ? const Color(0xFF767676) : background,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: size * 0.42),
        ),
      ),
    );
  }
}
