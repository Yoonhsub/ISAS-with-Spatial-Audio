import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'backend_api_client.dart';

/// Durable unresolved user action. No credentials are stored here.
class RideCreationIntentStore {
  String _transferSlot(String uid) => 'mobi.ride.transfer.v1.${Uri.encodeComponent(uid)}';

  Future<Map<String, String>?> pendingTransfer(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_transferSlot(uid));
    return raw == null ? null : Map<String, String>.from(jsonDecode(raw) as Map);
  }

  Future<void> beginTransfer(String uid, String parent, String busNo) async {
    final pending = await pendingTransfer(uid);
    if (pending != null && (pending['requestId'] != parent || pending['busNo'] != busNo)) {
      throw StateError('이전 환승 요청 결과를 먼저 확인해 주세요.');
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_transferSlot(uid), jsonEncode({'requestId': parent, 'busNo': busNo}))) {
      throw StateError('환승 재시도 정보를 저장하지 못했습니다.');
    }
  }

  Future<void> completeTransfer(String uid, String parent) async {
    final pending = await pendingTransfer(uid);
    if (pending?['requestId'] == parent) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_transferSlot(uid));
    }
  }

  String _slot(String uid) =>
      'mobi.ride.pending.v1.${Uri.encodeComponent(uid)}';

  String _activeSlot(String uid) =>
      'mobi.ride.active.v1.${Uri.encodeComponent(uid)}';

  Future<String?> activeRequest(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final id = prefs.getString(_activeSlot(uid));
    return id != null && RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)
        ? id
        : null;
  }

  Future<void> rememberRequest(String uid, String requestId) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_activeSlot(uid), requestId)) {
      throw StateError('새로고침 복구 정보를 저장하지 못했습니다. 요청 ID: $requestId');
    }
  }

  Future<void> clearActive(String uid, String requestId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (prefs.getString(_activeSlot(uid)) != requestId) return;
    for (final key in prefs.getKeys().where((key) =>
        key == _activeSlot(uid) || key.startsWith('${_activeSlot(uid)}.session.'))) {
      if (prefs.getString(key) == requestId) await prefs.remove(key);
    }
  }

  String _sessionSlot(String uid, String sessionId) =>
      '${_activeSlot(uid)}.session.${Uri.encodeComponent(sessionId)}';

  Future<void> bindSession(String uid, String sessionId, String requestId) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_sessionSlot(uid, sessionId), requestId)) {
      throw StateError('안내 세션에 요청을 연결하지 못했습니다.');
    }
  }

  Future<String?> sessionRequest(String uid, String sessionId) async {
    final active = await activeRequest(uid);
    final prefs = await SharedPreferences.getInstance();
    return active != null && prefs.getString(_sessionSlot(uid, sessionId)) == active
        ? active : null;
  }

  Future<String?> sessionForActiveRequest(String uid, String requestId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (prefs.getString(_activeSlot(uid)) != requestId) return null;
    final prefix = '${_activeSlot(uid)}.session.';
    final keys = prefs.getKeys().where(
        (key) => key.startsWith(prefix) && prefs.getString(key) == requestId);
    return keys.length == 1 ? keys.single.substring(prefix.length) : null;
  }

  Future<String> begin(RideRequestDraft draft) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final slot = _slot(draft.userId);
    final body = jsonEncode(draft.toJson());
    final saved = prefs.getString(slot);
    if (saved != null) {
      final pending = jsonDecode(saved) as Map<String, dynamic>;
      if (pending['body'] != body) {
        throw StateError('이전 탑승 요청의 결과가 아직 확인되지 않았습니다. 이전 노선을 선택해 재시도해 주세요.');
      }
      return pending['key'] as String;
    }
    final random = Random.secure();
    final key = List.generate(
            24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    if (!await prefs.setString(slot, jsonEncode({'key': key, 'body': body}))) {
      throw StateError('재시도 정보를 저장할 수 없어 요청을 보내지 않았습니다.');
    }
    return key;
  }

  Future<void> complete(String uid, String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final saved = prefs.getString(_slot(uid));
    if (saved != null &&
        (jsonDecode(saved) as Map<String, dynamic>)['key'] == key) {
      await prefs.remove(_slot(uid));
    }
  }
}
