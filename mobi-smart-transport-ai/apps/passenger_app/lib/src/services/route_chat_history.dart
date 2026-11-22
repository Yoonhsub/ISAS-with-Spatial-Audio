import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/chat_message.dart';

/// A transcript snapshot, not a restorable server session.
class SavedRouteChat {
  SavedRouteChat({
    required this.id,
    required List<ChatMessage> messages,
    required DateTime updatedAt,
  })  : messages = List<ChatMessage>.unmodifiable(
          messages.where(
            (message) => !message.isThinking && message.text.trim().isNotEmpty,
          ),
        ),
        updatedAt = updatedAt.toUtc();

  final String id;
  final List<ChatMessage> messages;
  final DateTime updatedAt;

  String get title {
    for (final message in messages) {
      if (message.isUser) return message.text.trim();
    }
    return messages.isEmpty ? '노선 대화 기록' : messages.first.text.trim();
  }

  Map<String, Object> _toJson() => {
        'id': id,
        'updatedAt': updatedAt.toIso8601String(),
        'messages': [
          for (final message in messages)
            {
              'text': message.text,
              'isUser': message.isUser,
              'timestamp': message.timestamp.toUtc().toIso8601String(),
              'source': message.source,
              'kind': message.kind,
            },
        ],
      };

  static SavedRouteChat? _fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final id = value['id'];
    final updatedAtString = value['updatedAt'];
    final messageValues = value['messages'];
    if (id is! String ||
        id.trim().isEmpty ||
        updatedAtString is! String ||
        messageValues is! List) {
      return null;
    }
    final updatedAt = DateTime.tryParse(updatedAtString);
    if (updatedAt == null) return null;

    final messages = <ChatMessage>[];
    for (final message in messageValues) {
      if (message is! Map<String, dynamic>) continue;
      final text = message['text'];
      final isUser = message['isUser'];
      final timestampString = message['timestamp'];
      final source = message['source'];
      final kind = message['kind'];
      if (text is! String ||
          text.trim().isEmpty ||
          isUser is! bool ||
          timestampString is! String ||
          kind == 'thinking') {
        continue;
      }
      final timestamp = DateTime.tryParse(timestampString);
      if (timestamp == null) continue;
      messages.add(ChatMessage(
        text: text,
        isUser: isUser,
        timestamp: timestamp.toUtc(),
        source: source is String ? source : 'chat',
        kind: kind is String ? kind : 'message',
      ));
    }
    if (messages.isEmpty) return null;
    return SavedRouteChat(id: id, messages: messages, updatedAt: updatedAt);
  }
}

/// Local-only snapshots. The caller supplies a stable, unambiguous scope for
/// the authenticated account, endpoint and data mode. No anonymous fallback
/// store is used.
class RouteChatHistoryStore {
  static const _limit = 3;
  static final _writes = <String, Future<List<SavedRouteChat>>>{};

  String _key(String scope) =>
      'mobi.route_chat_history.v1.${sha256.convert(utf8.encode(scope))}';

  Future<List<SavedRouteChat>> load(String scope) async {
    if (scope.trim().isEmpty) return const [];
    final key = _key(scope);
    final writing = _writes[key];
    if (writing != null) {
      try {
        await writing;
      } catch (_) {
        // A failed save does not prevent reading the previous snapshot.
      }
    }
    final preferences = await SharedPreferences.getInstance();
    return _read(preferences, key);
  }

  Future<List<SavedRouteChat>> save(String scope, SavedRouteChat entry) async {
    if (scope.trim().isEmpty) return const [];
    if (entry.id.trim().isEmpty || entry.messages.isEmpty) return load(scope);

    final key = _key(scope);
    final previousWrite = _writes[key];
    final writing = _write(key, entry, previousWrite);
    _writes[key] = writing;
    try {
      return await writing;
    } finally {
      if (identical(_writes[key], writing)) _writes.remove(key);
    }
  }

  Future<List<SavedRouteChat>> _write(
    String key,
    SavedRouteChat entry,
    Future<List<SavedRouteChat>>? previousWrite,
  ) async {
    if (previousWrite != null) {
      try {
        await previousWrite;
      } catch (_) {
        // Keep the queue usable after a persistence failure.
      }
    }
    final preferences = await SharedPreferences.getInstance();
    final result = _ordered([
      // Put the snapshot being saved first so equal timestamps replace it.
      entry,
      ..._read(preferences, key),
    ]);
    final encoded = jsonEncode([for (final chat in result) chat._toJson()]);
    if (!await preferences.setString(key, encoded)) {
      // The legacy preferences API updates its in-memory cache before the
      // platform write. Reload so callers won't see an unsaved snapshot.
      await preferences.reload();
      throw StateError('Route chat history could not be saved.');
    }
    return result;
  }

  static List<SavedRouteChat> _read(
    SharedPreferences preferences,
    String key,
  ) {
    final raw = preferences.get(key);
    if (raw is! String) return const [];
    try {
      final values = jsonDecode(raw);
      if (values is! List) return const [];
      return _ordered(
        values.map(SavedRouteChat._fromJson).whereType<SavedRouteChat>(),
      );
    } on FormatException {
      return const [];
    }
  }

  static List<SavedRouteChat> _ordered(Iterable<SavedRouteChat> entries) {
    final byId = <String, SavedRouteChat>{};
    for (final entry in entries) {
      final current = byId[entry.id];
      if (current == null || entry.updatedAt.isAfter(current.updatedAt)) {
        byId[entry.id] = entry;
      }
    }
    final ordered = byId.values.toList()
      ..sort((a, b) {
        final recentFirst = b.updatedAt.compareTo(a.updatedAt);
        return recentFirst == 0 ? a.id.compareTo(b.id) : recentFirst;
      });
    return List<SavedRouteChat>.unmodifiable(ordered.take(_limit));
  }
}
