import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/route_chat_history.dart';
import 'package:mobi_passenger_app/src/widgets/chat_message.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _scope = 'test-account|https://one.example|live';

DateTime _at(int minute) => DateTime.utc(2026, 11, 20, 10, minute);

String _key(String scope) =>
    'mobi.route_chat_history.v1.${sha256.convert(utf8.encode(scope))}';

ChatMessage _message(
  String text, {
  bool isUser = true,
  String source = 'chat',
  String kind = 'message',
  DateTime? timestamp,
}) =>
    ChatMessage(
      text: text,
      isUser: isUser,
      source: source,
      kind: kind,
      timestamp: timestamp ?? _at(0),
    );

SavedRouteChat _chat(String id, int minute, [String? text]) => SavedRouteChat(
      id: id,
      messages: [_message(text ?? id)],
      updatedAt: _at(minute),
    );

Iterable<String> _ids(List<SavedRouteChat> chats) => chats.map((chat) => chat.id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('retains three most recent chats and replaces the same id', () async {
    final store = RouteChatHistoryStore();
    await store.save(_scope, _chat('a', 1));
    await store.save(_scope, _chat('c', 3));
    await store.save(_scope, _chat('b', 2));
    final saved = await store.save(_scope, _chat('d', 4));
    expect(_ids(saved), ['d', 'c', 'b']);

    await store.save(_scope, _chat('c', 5, 'updated question'));
    await store.save(_scope, _chat('c', 1, 'older stale snapshot'));
    final persisted = await RouteChatHistoryStore().load(_scope);
    expect(_ids(persisted), ['c', 'd', 'b']);
    expect(persisted.first.title, 'updated question');
    expect(persisted.first.updatedAt, _at(5));
  });

  test('isolates account, endpoint, and data mode', () async {
    final store = RouteChatHistoryStore();
    const otherScopes = [
      'other-test-account|https://one.example|live',
      'test-account|https://other.example|live',
      'test-account|https://one.example|mock',
    ];
    await store.save(_scope, _chat('mine', 1));
    for (final scope in otherScopes) {
      expect(await store.load(scope), isEmpty);
      await store.save(scope, _chat('other', 2));
      expect(_ids(await store.load(scope)), ['other']);
    }
    expect(_ids(await store.load(_scope)), ['mine']);
    expect(await store.save(' ', _chat('anonymous', 2)), isEmpty);
    expect(await store.load(' '), isEmpty);
  });

  test('filters transient replies and preserves message data and order',
      () async {
    final store = RouteChatHistoryStore();
    final date = DateTime.parse('2026-11-20T20:00:00+09:00');
    final entry = SavedRouteChat(
      id: 'dialogue',
      messages: [
        _message('질문을 말씀하세요.', isUser: false),
        _message('  711번 어디로 가?  ', source: 'voice', timestamp: date),
        _message('생각 중', isUser: false, kind: 'thinking'),
        _message('  '),
        _message('청주대학교 쪽입니다.', isUser: false),
      ],
      updatedAt: date.toLocal(),
    );

    await store.save(_scope, entry);
    await store.save(
      _scope,
      SavedRouteChat(
        id: 'only-thinking',
        messages: [_message('생각 중', kind: 'thinking')],
        updatedAt: date,
      ),
    );
    final chat = (await store.load(_scope)).single;
    expect(chat.updatedAt.isUtc, isTrue);
    expect(chat.title, '711번 어디로 가?');
    expect(
      chat.messages.map((message) => message.text),
      ['질문을 말씀하세요.', '  711번 어디로 가?  ', '청주대학교 쪽입니다.'],
    );
    expect(chat.messages[1].isUser, isTrue);
    expect(chat.messages[1].source, 'voice');
    expect(chat.messages[1].timestamp, date.toUtc());
  });

  test('loads other entries after one malformed row or message', () async {
    SharedPreferences.setMockInitialValues({
      _key(_scope): jsonEncode([
        false,
        {'id': 'bad', 'updatedAt': 'not a date', 'messages': []},
        {
          'id': 'valid',
          'updatedAt': _at(2).toIso8601String(),
          'messages': [
            {'timestamp': _at(1).toIso8601String(), 'text': 12},
            {
              'timestamp': _at(1).toIso8601String(),
              'text': '노선 질문',
              'isUser': true,
            },
          ],
        },
      ]),
    });
    final result = await RouteChatHistoryStore().load(_scope);
    expect(_ids(result), ['valid']);
    expect(result.single.messages.single.text, '노선 질문');
    expect(result.single.messages.single.source, 'chat');
  });

  test('recovers safely from malformed JSON and unexpected preference types',
      () async {
    final store = RouteChatHistoryStore();
    SharedPreferences.setMockInitialValues({_key(_scope): '{invalid JSON'});
    expect(await store.load(_scope), isEmpty);
    expect(_ids(await store.save(_scope, _chat('recover', 1))), ['recover']);

    SharedPreferences.setMockInitialValues({_key(_scope): false});
    expect(await store.load(_scope), isEmpty);
    expect(_ids(await store.save(_scope, _chat('recover', 1))), ['recover']);
  });

  test('serializes concurrent writes with deterministic timestamp ties',
      () async {
    final store = RouteChatHistoryStore();
    final saves = [
      store.save(_scope, _chat('z', 1)),
      RouteChatHistoryStore().save(_scope, _chat('x', 1)),
      store.save(_scope, _chat('y', 1)),
    ];
    final finalRead = store.load(_scope);
    await Future.wait(saves);
    expect(_ids(await finalRead), ['x', 'y', 'z']);
  });
}
