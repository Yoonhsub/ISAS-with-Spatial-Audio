import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'speech_priority_coordinator.dart';

/// One successful announcement per account/request, including after reopening.
class RideAcceptanceAnnouncement {
  static final Set<String> _pending = {};
  static const message = '탑승 요청이 수락되었습니다.';

  static Future<void> announce({required String uid, required String requestId,
      required SpeechPriorityCoordinator speech, required Object owner,
      required bool Function() current}) async {
    final key = 'mobi.ride.accepted.v1.${jsonEncode([uid, requestId])}';
    if (!current() || !_pending.add(key)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!current() || prefs.getBool(key) == true) return;
      final spoken = await speech.speakObservation(owner, message, current);
      if (spoken && current()) await prefs.setBool(key, true);
    } catch (_) {
      // A later valid status poll retries an unavailable or interrupted voice.
    } finally {
      _pending.remove(key);
    }
  }
}
