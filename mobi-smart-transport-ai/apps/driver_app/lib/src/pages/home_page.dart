import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';

import '../services/backend_api_client.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.apiClient, this.session});
  final BackendApiClient? apiClient;
  final AuthSession? session;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _apiBaseUrl = String.fromEnvironment(
    'MOBI_API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );

  late final BackendApiClient _backendApiClient;
  late final AuthSession _auth;
  StreamSubscription<AuthAccount?>? _subscription;
  String? _uid;
  int _epoch = 0;
  Timer? _poll;
  bool _history = false;
  static const _terminal = {'DENIED', 'REJECTED', 'CANCELLED', 'COMPLETED'};

  bool get _hasActiveRequests =>
      _rideRequestsResult?.requests
          .any((request) => !_terminal.contains(request.statusLabel)) ??
      false;

  void _syncPolling() {
    if (!mounted || _uid == null || _hasActiveRequests) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (!_hasActiveRequests) _refreshDriverRideRequests();
    });
  }

  bool _current(int epoch, String? uid) =>
      mounted &&
      epoch == _epoch &&
      uid == _uid &&
      uid == _auth.currentAccount?.uid;

  @override
  void dispose() {
    _epoch++;
    _poll?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _signOut() async {
    _epoch++;
    setState(() {
      _rideRequestsResult = null;
      _statusUpdateResult = null;
      _isLoadingRideRequests = true;
    });
    _poll?.cancel();
    _poll = null;
    try {
      await _auth.signOut();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('로그아웃하지 못했습니다. 다시 시도해 주세요.')));
      }
    }
  }

  BackendHealthStatus? _backendHealthStatus;
  bool _isLoadingBackendHealth = true;

  DriverRideRequestsResult? _rideRequestsResult;
  bool _isLoadingRideRequests = true;

  RideRequestStatusUpdateResult? _statusUpdateResult;
  bool _isUpdatingRideRequestStatus = false;

  @override
  void initState() {
    super.initState();
    _auth = widget.session ?? FirebaseAuthSession.instance;
    _backendApiClient = widget.apiClient ??
        BackendApiClient(baseUrl: _apiBaseUrl, useMockData: false);
    _uid = _auth.currentAccount?.uid;
    _subscription = _auth.authStateChanges.listen((account) {
      if (account?.uid != _auth.currentAccount?.uid) return;
      if (account?.uid == _uid) return;
      setState(() {
        _epoch++;
        _uid = account?.uid;
        _rideRequestsResult = null;
        _statusUpdateResult = null;
        _isUpdatingRideRequestStatus = false;
        _isLoadingRideRequests = true;
      });
      _syncPolling();
      _loadDriverRideRequests();
    });
    _syncPolling();
    _loadBackendHealthStatus();
    _loadDriverRideRequests();
  }

  Future<void> _loadBackendHealthStatus() async {
    final healthStatus = await _backendApiClient.fetchHealthStatus();

    if (!mounted) return;

    setState(() {
      _backendHealthStatus = healthStatus;
      _isLoadingBackendHealth = false;
    });
  }

  Future<void> _loadDriverRideRequests() async {
    final epoch = _epoch;
    final uid = _uid;
    if (uid == null) {
      if (mounted) setState(() => _isLoadingRideRequests = false);
      return;
    }
    try {
      final driverId = await _auth.getCustomClaim(
        'mobi_driver_id',
        forceRefresh: true,
      );
      if (!_current(epoch, uid)) return;
      if (driverId is! String || driverId.isEmpty) {
        if (!_current(epoch, uid)) return;
        setState(() {
          _rideRequestsResult = const DriverRideRequestsResult(
            statusLabel: '기사 계정 배정 필요',
            description: '서버 관리자가 이 Firebase 계정에 기사 역할과 기사 ID를 등록해야 합니다.',
            requests: [],
          );
          _isLoadingRideRequests = false;
        });
        return;
      }
      final result = await _backendApiClient.fetchDriverRideRequests(
        driverId: driverId,
      );
      if (!_current(epoch, uid)) return;
      setState(() {
        _rideRequestsResult = result;
        _isLoadingRideRequests = false;
      });
      if (result.isSuccess) _syncPolling();
    } catch (_) {
      if (!_current(epoch, uid)) return;
      setState(() {
        _rideRequestsResult = const DriverRideRequestsResult(
          statusLabel: '기사 계정 확인 실패',
          description: '인증 정보 또는 네트워크를 확인할 수 없습니다. 다시 로그인해 주세요.',
          requests: [],
        );
        _isLoadingRideRequests = false;
      });
    }
  }

  Future<void> _refreshDriverRideRequests() async {
    if (_isLoadingRideRequests ||
        _isUpdatingRideRequestStatus ||
        _uid == null) {
      return;
    }
    // HTTP polling path used by the refresh button and future FCM callbacks.
    setState(() {
      _isLoadingRideRequests = true;
    });

    await _loadDriverRideRequests();
  }

  Future<void> _updateRideRequest(String? requestId, String status) async {
    if (_isUpdatingRideRequestStatus ||
        _isLoadingRideRequests ||
        _uid == null) {
      return;
    }
    final epoch = _epoch;
    final uid = _uid;
    if (requestId == null || requestId.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('상태를 변경할 탑승 요청 식별자가 없습니다.')));
      return;
    }

    setState(() {
      _isUpdatingRideRequestStatus = true;
    });

    final result = await _backendApiClient.updateRideRequestStatus(
      requestId: requestId,
      status: status,
    );

    if (!_current(epoch, uid)) return;

    setState(() {
      _statusUpdateResult = result.isSuccess ? null : result;
      _isUpdatingRideRequestStatus = false;
    });

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.description)));

    if (result.isSuccess || result.httpStatus == 409) {
      await _refreshDriverRideRequests();
    }
  }

  @override
  Widget build(BuildContext context) {
    final rideRequests =
        (_rideRequestsResult?.requests ?? const <DriverRideRequestItem>[])
            .where((r) => _terminal.contains(r.statusLabel) == _history)
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('MOBI. 기사',
            style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: '로그아웃',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: RefreshIndicator(
              onRefresh: _refreshDriverRideRequests,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const _HeaderSection(),
                  const SizedBox(height: 16),
                  SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      title: const Text('이전 요청 기록',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      subtitle: Text(_history
                          ? '거부·취소·완료된 요청을 표시합니다.'
                          : '진행 중인 탑승 요청을 표시합니다.'),
                      value: _history,
                      onChanged: (value) => setState(() => _history = value)),
                  const SizedBox(height: 16),
                  _InfoCard(
                    title: '서비스 연결',
                    statusLabel: _isLoadingBackendHealth
                        ? '확인 중'
                        : (_backendHealthStatus?.isAvailable ?? false)
                            ? '연결 성공'
                            : '연결 실패',
                    description: _isLoadingBackendHealth
                        ? '연결을 확인하고 있습니다.'
                        : (_backendHealthStatus?.isAvailable ?? false)
                            ? '승객이 보낸 탑승 요청을 받을 준비가 되었습니다.'
                            : '연결을 확인할 수 없습니다. 잠시 후 다시 시도해 주세요.',
                    icon: Icons.cloud_done_outlined,
                    semanticHint: '실제 /health API 연결 성공 또는 실패 상태를 표시하는 영역입니다.',
                  ),
                  const SizedBox(height: 16),
                  _InfoCard(
                    title: '탑승 요청 목록',
                    statusLabel: _isLoadingRideRequests
                        ? '불러오는 중'
                        : _rideRequestsResult?.statusLabel ?? '요청 없음',
                    description: _rideRequestsResult?.description ??
                        '기사에게 배정된 탑승 요청 목록을 불러오는 중입니다.',
                    icon: Icons.accessible_forward_outlined,
                    semanticHint: '기사에게 배정된 탑승 요청 목록 상태를 표시하는 영역입니다.',
                  ),
                  if (_statusUpdateResult != null) ...[
                    const SizedBox(height: 12),
                    _InfoCard(
                      title: '상태 변경 결과',
                      statusLabel: _isUpdatingRideRequestStatus
                          ? '변경 중'
                          : _statusUpdateResult?.statusLabel ?? '대기',
                      description: _statusUpdateResult?.description ??
                          '탑승 요청 상태 변경 결과를 기다리는 중입니다.',
                      icon: Icons.check_circle_outline,
                      semanticHint: _statusUpdateResult?.semanticHint ??
                          '탑승 요청 상태 변경 결과를 표시하는 영역입니다.',
                    ),
                  ],
                  const SizedBox(height: 12),
                  Semantics(
                    button: true,
                    label: _isLoadingRideRequests
                        ? '탑승 요청 목록 새로고침 중'
                        : '탑승 요청 목록 새로고침',
                    hint: '두 번 탭하면 기사에게 배정된 탑승 요청 목록을 다시 불러옵니다.',
                    child: SizedBox(
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: _isLoadingRideRequests ||
                                _isUpdatingRideRequestStatus ||
                                _uid == null
                            ? null
                            : _refreshDriverRideRequests,
                        icon: Icon(
                          _isLoadingRideRequests
                              ? Icons.hourglass_empty
                              : Icons.refresh_outlined,
                        ),
                        label: Text(
                          _isLoadingRideRequests ? '불러오는 중...' : '요청 목록 새로고침',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_isLoadingRideRequests)
                    const _InfoCard(
                      title: '요청 카드',
                      statusLabel: '불러오는 중',
                      description: '기사에게 배정된 탑승 요청을 불러오는 중입니다.',
                      icon: Icons.hourglass_empty,
                      semanticHint: '탑승 요청 목록 로딩 상태입니다.',
                    )
                  else if (rideRequests.isEmpty)
                    const _InfoCard(
                      title: '요청 카드',
                      statusLabel: '요청 없음',
                      description: '현재 표시할 탑승 요청이 없습니다.',
                      icon: Icons.inbox_outlined,
                      semanticHint: '기사에게 배정된 탑승 요청이 없는 상태입니다.',
                    )
                  else
                    ...rideRequests.map(
                      (request) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _InfoCard(
                              title: request.requestLabel,
                              statusLabel: request.statusLabel,
                              description: request.description,
                              icon: Icons.assignment_outlined,
                              semanticHint: request.semanticHint,
                            ),
                            const SizedBox(height: 8),
                            if (!_history)
                              Semantics(
                                button: true,
                                label: '${request.requestLabel} 수락',
                                hint: '두 번 탭하면 해당 탑승 요청을 ACCEPTED 상태로 변경합니다.',
                                child: SizedBox(
                                  height: 56,
                                  child: ElevatedButton.icon(
                                    onPressed: _isUpdatingRideRequestStatus ||
                                            !{'WAITING', 'NOTIFIED'}
                                                .contains(request.statusLabel)
                                        ? null
                                        : () => _updateRideRequest(
                                            request.requestId, 'ACCEPTED'),
                                    icon: Icon(
                                      _isUpdatingRideRequestStatus
                                          ? Icons.hourglass_empty
                                          : Icons.check_circle_outline,
                                    ),
                                    label: Text(
                                      _isUpdatingRideRequestStatus
                                          ? '처리 중...'
                                          : '요청 수락',
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (!_history &&
                                {'WAITING', 'NOTIFIED'}
                                    .contains(request.statusLabel))
                              Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: OutlinedButton(
                                      onPressed: _isUpdatingRideRequestStatus
                                          ? null
                                          : () => _updateRideRequest(
                                              request.requestId, 'DENIED'),
                                      child: const Text('요청 거부',
                                          style: TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w700)))),
                            if (!_history && request.statusLabel == 'ACCEPTED')
                              Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: OutlinedButton(
                                      onPressed: _isUpdatingRideRequestStatus
                                          ? null
                                          : () => _updateRideRequest(
                                              request.requestId, 'CANCELLED'),
                                      child: const Text('승인한 요청 취소',
                                          style: TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w700)))),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                          _poll?.isActive ?? false
                              ? '진행 중인 요청이 없을 때 새 요청을 1분마다 확인합니다.'
                              : '자동 새로고침이 중지되어 있습니다. 필요하면 요청 목록을 직접 새로고침해 주세요.',
                          textAlign: TextAlign.center)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderSection extends StatelessWidget {
  const _HeaderSection();

  @override
  Widget build(BuildContext context) => Semantics(
        header: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.directions_bus_filled_outlined,
                  color: Colors.white, size: 32),
              SizedBox(height: 16),
              Text('탑승 요청을 확인하세요',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      height: 1.4)),
              SizedBox(height: 8),
              Text('승객이 선택한 버스의 탑승 요청을 승인하거나 거부할 수 있습니다.',
                  style: TextStyle(
                      color: Colors.white, fontSize: 17, height: 1.5)),
            ],
          ),
        ),
      );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.statusLabel,
    required this.description,
    required this.icon,
    required this.semanticHint,
  });

  final String title;
  final String statusLabel;
  final String description;
  final IconData icon;
  final String semanticHint;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$title, 상태 $statusLabel, $description',
      hint: semanticHint,
      child: Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _InfoHeader(title: title, statusLabel: statusLabel),
                    const SizedBox(height: 10),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoHeader extends StatelessWidget {
  const _InfoHeader({required this.title, required this.statusLabel});

  final String title;
  final String statusLabel;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        Semantics(
          label: '상태 $statusLabel',
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: statusLabel == 'ACCEPTED'
                  ? const Color(0xFF111111)
                  : Colors.white,
              border: Border.all(color: const Color(0xFF111111), width: 2),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                statusLabel,
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: statusLabel == 'ACCEPTED'
                        ? Colors.white
                        : const Color(0xFF111111)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
