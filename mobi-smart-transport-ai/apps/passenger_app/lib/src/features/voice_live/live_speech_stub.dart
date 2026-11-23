import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Native recognition opens once per tap. End/error callbacks must never start
/// another Android session while the previous session is still finishing.
class LiveSpeechRecognizer {
  final SpeechToText _speech = SpeechToText();
  // SpeechToText is a process-wide singleton, including its callbacks.
  static Future<void> _operations = Future<void>.value();
  static LiveSpeechRecognizer? _owner;
  void Function(String text, bool isFinal)? _onResult;
  void Function(String state)? _onState;
  String _locale = 'ko_KR';
  bool _ready = false;
  bool _active = false;
  bool _listenOpen = false;
  int _generation = 0;
  Future<bool>? _pendingListen;
  Timer? _startTimeout;

  bool get isContinuous => false;
  bool get supported => true;
  bool get needsRecovery => false;
  bool get isListening =>
      identical(_owner, this) && _active && _listenOpen && _speech.isListening;

  static Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<bool> start({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
    required void Function(String state) onState,
  }) {
    _onResult = onResult;
    _onState = onState;
    _locale = localeId;
    _active = true;
    return _requestListen(initialize: true);
  }

  Future<bool> _requestListen({bool initialize = false}) {
    final pending = _pendingListen;
    if (pending != null) return pending;
    final ticket = _generation;
    final request = _serialize(() async {
      if (!_active || ticket != _generation) return false;
      // Suppress callbacks from cancellation before attaching the new page.
      final previous = _owner;
      if (previous != null && !identical(previous, this)) {
        previous._active = false;
        previous._listenOpen = false;
        previous._generation++;
        previous._startTimeout?.cancel();
      }
      _owner = null;
      try {
        await _speech.cancel();
        // The Android plugin posts cancel/start onto the main handler. Give its
        // terminal callbacks time to finish before opening the next session.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!_active || ticket != _generation) return false;
        _owner = this;
        if (initialize || !_ready) {
          _ready = await _speech.initialize(
            onStatus: _handleStatus,
            onError: _handleError,
          );
        }
        if (!_active || ticket != _generation || !_ready) return false;
        // initialize() does not replace listeners after its first success.
        _speech.statusListener = _handleStatus;
        _speech.errorListener = _handleError;
        await _speech.listen(
          localeId: _locale,
          pauseFor: const Duration(seconds: 5),
          listenFor: const Duration(seconds: 120),
          onResult: (result) {
            if (_active && identical(_owner, this) && ticket == _generation) {
              _onResult?.call(result.recognizedWords, result.finalResult);
            }
          },
          listenOptions: SpeechListenOptions(
            partialResults: true,
            cancelOnError: false, // Cancellation is serialized by this adapter.
            listenMode: ListenMode.dictation,
          ),
        );
        if (!_active || ticket != _generation) return false;
        if (!_speech.isListening) {
          _startTimeout?.cancel();
          _startTimeout = Timer(const Duration(seconds: 3), () {
            if (_active && ticket == _generation && !isListening) {
              _onState?.call('error_start_timeout');
              setActive(false);
            }
          });
        }
        return true;
      } catch (_) {
        if (_active && ticket == _generation) {
          _onState?.call('error_start_failed');
          setActive(false);
        }
        return false;
      }
    });
    _pendingListen = request;
    unawaited(request.then((_) {
      if (identical(_pendingListen, request)) _pendingListen = null;
    }));
    return request;
  }

  void _handleStatus(String status) {
    if (!_active || !identical(_owner, this)) return;
    _listenOpen = status == 'listening';
    _startTimeout?.cancel();
    _onState?.call(status);
  }

  void _handleError(SpeechRecognitionError error) {
    if (!_active || !identical(_owner, this)) return;
    _listenOpen = false;
    _startTimeout?.cancel();
    _onState?.call(error.errorMsg);
  }

  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    if (!active) {
      _listenOpen = false;
      _generation++;
      _pendingListen = null;
      _startTimeout?.cancel();
      unawaited(_cancelOwnedSession());
    }
  }

  Future<void> _cancelOwnedSession() => _serialize(() async {
        if (!identical(_owner, this)) return;
        _owner = null;
        try {
          await _speech.cancel();
        } catch (_) {}
      });

  bool resume() {
    if (!_ready) return false;
    _active = true;
    if (isListening || _pendingListen != null) return true;
    unawaited(_requestListen());
    return true;
  }

  Future<void> stop() async {
    _active = false;
    _listenOpen = false;
    _generation++;
    _pendingListen = null;
    _startTimeout?.cancel();
    await _cancelOwnedSession();
  }
}
