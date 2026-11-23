import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';

import '../services/backend_api_client.dart';
import '../services/confirmed_ride_selection.dart';
import '../services/ride_creation_intent.dart';
import '../services/ride_acceptance_announcement.dart';
import '../widgets/described_action.dart';
import '../services/speech_priority_coordinator.dart';

/// The business ride UI uses the existing HTTP contract, never direct RTDB.
class RideRequestPanel extends StatefulWidget {
  const RideRequestPanel(
      {super.key,
      required this.api,
      required this.draft,
      this.session,
      this.store,
      this.guidanceSessionId,
      this.canSubmit,
      this.selectionRevoked,
      this.compact = false,
      this.autoRefresh = false});
  final bool Function(RideRequestDraft)? canSubmit;
  final bool autoRefresh;
  final bool compact;
  final String? guidanceSessionId;
  final Future<void>? selectionRevoked;

  static Widget confirmed(
      {Key? key,
      required BackendApiClient api,
      required AuthSession session,
      bool compact = false,
      String? guidanceSessionId,
      RideCreationIntentStore? store,
      required ConfirmedRideSelection selection}) {
    return ValueListenableBuilder<RideRequestDraft?>(
        key: key,
        valueListenable: selection,
        builder: (_, draft, __) => RideRequestPanel(
            api: api,
            session: session,
            store: store,
            draft: draft,
            autoRefresh: true,
            compact: compact,
            guidanceSessionId: guidanceSessionId ?? selection.sessionId,
            selectionRevoked: selection.revoked,
            canSubmit: (candidate) => identical(selection.value, candidate)));
  }

  final BackendApiClient api;
  final RideRequestDraft? draft;
  final AuthSession? session;
  final RideCreationIntentStore? store;

  @override
  State<RideRequestPanel> createState() => _RideRequestPanelState();
}

class _RideRequestPanelState extends State<RideRequestPanel>
    with WidgetsBindingObserver {
  late final AuthSession _auth;
  late final RideCreationIntentStore _store;
  StreamSubscription<AuthAccount?>? _subscription;
  Timer? _poll;
  Completer<void>? _reading;
  bool _visible = true;
  bool _foreground = true;
  int _readGeneration = 0;
  String? _uid;
  String? _requestId;
  List<Map<String, dynamic>> _history = [];
  static const _terminal = {'DENIED', 'REJECTED', 'CANCELLED', 'COMPLETED'};
  String _status = '요청 전';
  String _message = '버스를 선택한 뒤 탑승 요청을 보내세요.';
  String? _actionIssue;
  bool _busy = false;
  int _epoch = 0;
  final _announcementOwner = Object();
  SpeechPriorityCoordinator? _announcementSpeech;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _auth = widget.session ?? FirebaseAuthSession.instance;
    _store = widget.store ?? RideCreationIntentStore();
    _uid = _auth.currentAccount?.uid;
    _subscription = _auth.authStateChanges.listen((account) {
      if (account?.uid != _auth.currentAccount?.uid) return;
      if (account?.uid == _uid) return;
      _stopReading();
      setState(() {
        _epoch++;
        _uid = account?.uid;
        _requestId = null;
        _history = [];
        _status = '요청 전';
        _actionIssue = null;
        _message = '현재 계정의 탑승 요청을 확인해 주세요.';
        _busy = false;
      });
      _restore();
    });
    _restore();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _announcementSpeech = ActionSpeechScope.of(context);
    final visible = ModalRoute.isCurrentOf(context) ?? true;
    if (visible == _visible) return;
    _visible = visible;
    _visibilityChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _visibilityChanged();
  }

  void _visibilityChanged() {
    if (_visible && _foreground) {
      _schedulePoll();
    } else {
      _stopReading();
    }
  }

  bool _current(int epoch, String? uid) =>
      mounted &&
      epoch == _epoch &&
      uid == _uid &&
      uid == _auth.currentAccount?.uid;

  Future<void> _restore() async {
    final uid = _uid;
    if (uid == null) return;
    final epoch = ++_epoch;
    setState(() => _busy = true);
    try {
      var id = await _store.activeRequest(uid);
      if (!_current(epoch, uid)) return;
      try {
        final records = await widget.api.fetchMyRideRequests();
        if (!_current(epoch, uid)) return;
        _history = records.where((r) => _terminal.contains(r['status'])).toList();
        final active = records.where((r) => !_terminal.contains(r['status']));
        if (active.isNotEmpty) {
          id = active.first['requestId'] as String;
          await _store.rememberRequest(uid, id);
        }
      } catch (_) { /* Existing request can still be recovered by its ID. */ }
      if (!_current(epoch, uid) || id == null) return;
      _requestId = id;
      if (!_visible || !_foreground) return;
      final generation = _readGeneration;
      final result = await _read(id);
      if (_current(epoch, uid) && generation == _readGeneration) _show(result);
    } catch (_) {
      if (_current(epoch, uid)) {
        setState(() {
          _actionIssue = '상태 조회 실패';
          _message = '요청 복구에 실패했습니다. 다시 조회해 주세요.';
        });
      }
    } finally {
      if (_current(epoch, uid)) {
        setState(() => _busy = false);
        _schedulePoll();
      }
    }
  }

  Future<RideRequestStatusResult> _read(String id) {
    final reading = _reading = Completer<void>();
    return widget.api
        .fetchRideRequestStatus(requestId: id, abortTrigger: reading.future)
        .whenComplete(() {
      if (!reading.isCompleted) reading.complete();
      if (identical(_reading, reading)) _reading = null;
    });
  }

  void _stopReading() {
    _stopAnnouncement();
    _readGeneration++;
    _poll?.cancel();
    _poll = null;
    _reading?.complete();
    _reading = null;
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (!_visible ||
        !_foreground ||
        !widget.autoRefresh ||
        _requestId == null ||
        {'DENIED', 'REJECTED', 'CANCELLED', 'COMPLETED'}.contains(_status)) {
      return;
    }
    _poll = Timer(const Duration(seconds: 5), () {
      if (!_busy && _current(_epoch, _uid)) {
        _readOrCancel(automatic: true);
      } else if (mounted && _current(_epoch, _uid)) {
        _schedulePoll();
      }
    });
  }

  void _show(RideRequestStatusResult result) {
    final id = _requestId, uid = _uid;
    if (result.isSuccess && _terminal.contains(result.statusLabel) && id != null && uid != null) {
      unawaited(_store.clearActive(uid, id).catchError((Object _) {}));
      _history.removeWhere((r) => r['requestId'] == id);
      _history.insert(0, {'requestId': id, 'status': result.statusLabel});
      _requestId = null;
    }
    setState(() {
      if (result.isSuccess || result.httpStatus == 409) {
        _status = result.statusLabel;
      }
      _actionIssue = result.isSuccess ? null : result.statusLabel;
      _message = result.description;
    });
    final accepted = result.acceptedRide;
    final speech = _announcementSpeech;
    if (result.isSuccess && accepted != null && accepted.userId == uid &&
        accepted.requestId == id && speech != null && uid != null && id != null) {
      final generation = _readGeneration;
      unawaited(RideAcceptanceAnnouncement.announce(uid: uid, requestId: id,
          speech: speech, owner: _announcementOwner,
          current: () => mounted && _visible && _foreground &&
              generation == _readGeneration && _uid == uid &&
              _auth.currentAccount?.uid == uid && _requestId == id &&
              _status == 'ACCEPTED' && _actionIssue == null));
    } else {
      _stopAnnouncement();
    }
  }

  void _stopAnnouncement() {
    final speech = _announcementSpeech;
    if (speech != null) {
      unawaited(speech.stopObservation(_announcementOwner).catchError((Object _) {}));
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    final uid = _uid;
    final draft = widget.draft;
    final sessionId = widget.guidanceSessionId;
    if (uid == null ||
        uid != _auth.currentAccount?.uid ||
        draft == null ||
        draft.userId != uid ||
        widget.canSubmit?.call(draft) == false) {
      return;
    }
    final epoch = ++_epoch;
    setState(() => _busy = true);
    try {
      final key = await _store.begin(draft);
      if (!_current(epoch, uid) || widget.canSubmit?.call(draft) == false) {
        await _store.complete(uid, key);
        return;
      }
      final result = await widget.api.createRideRequest(
          draft: draft,
          idempotencyKey: key,
          guidanceSessionId: sessionId,
          abortTrigger: widget.selectionRevoked);
      if (!_current(epoch, uid)) return;
      setState(() {
        _actionIssue = result.isSuccess ? null : result.statusLabel;
        _message = result.description;
        // A failed retry must not replace the ID of an existing request.
        if (result.isSuccess) {
          _requestId = result.requestId;
          _status = result.statusLabel;
        }
      });
      if (result.isSuccess && result.requestId != null) {
        await _store.rememberRequest(uid, result.requestId!);
        if (_current(epoch, uid) && sessionId != null && widget.canSubmit?.call(draft) == true) {
          await _store.bindSession(uid, sessionId, result.requestId!);
        }
        await _store.complete(uid, key);
      }
    } catch (error) {
      if (_current(epoch, uid)) {
        setState(() {
          _actionIssue = error is AuthenticatedApiException
              ? error.userMessage
              : '요청 처리 실패';
          _message = error is AuthenticatedApiException
              ? error.userMessage
              : error is StateError
                  ? error.message.toString()
                  : '요청에 실패했습니다. 같은 요청으로 다시 시도해 주세요.';
        });
      }
    } finally {
      if (_current(epoch, uid)) {
        setState(() => _busy = false);
        _schedulePoll();
      }
    }
  }

  Future<void> _readOrCancel(
      {bool cancel = false, bool automatic = false}) async {
    if (_busy) return;
    final id = _requestId;
    if (id == null) {
      await _restore();
      return;
    }
    final uid = _uid;
    if (uid == null || uid != _auth.currentAccount?.uid) return;
    final epoch = ++_epoch;
    final generation = _readGeneration;
    if (automatic) {
      _busy = true;
    } else {
      setState(() => _busy = true);
    }
    try {
      final result =
          cancel ? await widget.api.cancelRideRequest(id) : await _read(id);
      if (_current(epoch, uid) && generation == _readGeneration) _show(result);
    } on AuthenticatedApiException catch (error) {
      if (_current(epoch, uid)) {
        setState(() {
          _actionIssue = _message = error.userMessage;
        });
      }
    } catch (_) {
      if (_current(epoch, uid)) {
        setState(() {
          _actionIssue = '통신 실패 · 다시 조회해 주세요';
          _message = '통신에 실패했습니다. 상태를 다시 조회해 주세요.';
        });
      }
    } finally {
      if (_current(epoch, uid)) {
        setState(() => _busy = false);
        _schedulePoll();
      }
    }
  }

  @override
  void dispose() {
    _epoch++;
    WidgetsBinding.instance.removeObserver(this);
    _stopReading();
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final terminal = {'DENIED', 'REJECTED', 'CANCELLED', 'COMPLETED'}.contains(_status);
    final displayStatus = widget.compact
        ? switch (_status) {
            'WAITING' => '수락 대기',
            'ACCEPTED' => '수락됨',
            'DENIED' || 'REJECTED' => '거절됨',
            'CANCELLED' => '취소됨',
            'COMPLETED' => '탑승 완료',
            _ => _status,
          }
        : _status;
    return Semantics(
        liveRegion: true,
        child: Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Material(color: Colors.transparent, child: ExpansionTile(title: const Text('이전 탑승 요청 기록'), children: [
                      if (_history.isEmpty) const ListTile(title: Text('이전 요청 없음')),
                      for (final record in _history)
                        ListTile(title: Text('${record['busNo'] ?? ''} ${record['status']}'),
                          subtitle: Text('${record['requestId']}')),
                    ])),
                    if (widget.compact) ...[
                      Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text('탑승 요청 상태',
                                style: Theme.of(context).textTheme.titleSmall),
                            Text(_busy ? '처리 중' : displayStatus,
                                key: const ValueKey('ride-status'),
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(fontWeight: FontWeight.bold)),
                          ]),
                      if (_actionIssue != null) Text(_actionIssue!),
                      const SizedBox(height: 10),
                    ] else ...[
                      const Text('탑승 요청 상태'),
                      Text(_busy ? '처리 중...' : _status,
                          key: const ValueKey('ride-status')),
                      Text(_message, key: const ValueKey('ride-message')),
                      if (_requestId != null)
                        SelectableText('요청 ID: $_requestId'),
                    ],
                    FilledButton.icon(
                        style: FilledButton.styleFrom(
                            minimumSize:
                                Size.fromHeight(widget.compact ? 48 : 64),
                            textStyle:
                                TextStyle(fontSize: widget.compact ? 16 : 20)),
                        onPressed: _busy ||
                                _uid == null ||
                                widget.draft == null ||
                                widget.draft?.userId != _uid ||
                                (_requestId != null && !terminal)
                            ? null
                            : _create,
                        icon: const Icon(Icons.send_outlined),
                        label: const Text('탑승 요청하기')),
                    if (widget.compact) const SizedBox(height: 8),
                    OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                            minimumSize:
                                Size.fromHeight(widget.compact ? 48 : 56),
                            textStyle:
                                TextStyle(fontSize: widget.compact ? 16 : 18)),
                        onPressed: _busy || _uid == null
                            ? null
                            : () => _readOrCancel(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('상태 조회')),
                    if (widget.compact) const SizedBox(height: 8),
                    OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                            minimumSize:
                                Size.fromHeight(widget.compact ? 48 : 56),
                            textStyle:
                                TextStyle(fontSize: widget.compact ? 16 : 18)),
                        onPressed: _busy ||
                                _requestId == null ||
                                terminal ||
                                _uid == null
                            ? null
                            : () => _readOrCancel(cancel: true),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('내 탑승 요청 취소')),
                  ],
                ))));
  }
}
