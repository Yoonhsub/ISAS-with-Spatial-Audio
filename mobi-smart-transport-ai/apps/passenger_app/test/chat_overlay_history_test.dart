import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/route_chat_history.dart';
import 'package:mobi_passenger_app/src/widgets/chat_overlay.dart';

SavedRouteChat _chat(String id, String title, int date) {
  final time = DateTime.utc(2026, 11, date);
  return SavedRouteChat(
    id: id,
    messages: [ChatMessage(text: title, isUser: true, timestamp: time)],
    updatedAt: time,
  );
}

Widget _app({
  required List<SavedRouteChat> chats,
  required ValueChanged<SavedRouteChat> onOpen,
  VoidCallback? onNew,
  VoidCallback? onReturn,
  bool busy = false,
  bool viewingSavedChat = false,
  double scale = 1,
  String? current,
}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData.fromView(
                WidgetsBinding.instance.platformDispatcher.views.first)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: ChatOverlay(
            messages: const [],
            isBusy: false,
            savedChats: chats,
            onSendMessage: (_) async {},
            onClose: () {},
            onNewChat: onNew,
            onOpenSavedChat: onOpen,
            historyBusy: busy,
            viewingSavedChat: viewingSavedChat,
            onReturnToCurrentChat: onReturn,
            activeChatId: current,
          ),
        ),
      ),
    );

void main() {
  testWidgets('saved chats are numbered newest first and open by id',
      (tester) async {
    final old = _chat('old', '충북대학교', 5);
    final recent = _chat('new', '청주역', 6);
    String? opened;
    await tester.pumpWidget(
      _app(chats: [old, recent], onOpen: (chat) => opened = chat.id),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('최근 대화'));
    await tester.pumpAndSettle();

    expect(find.text('1. 청주역'), findsOneWidget);
    expect(find.text('2. 충북대학교'), findsOneWidget);
    expect(find.textContaining('2026년 11월 6일'), findsOneWidget);
    await tester.tap(find.text('2. 충북대학교'));
    expect(opened, 'old');
  });

  testWidgets('busy history cannot open or create a chat', (tester) async {
    var callbacks = 0;
    await tester.pumpWidget(_app(
      chats: [_chat('chat', '청주역', 6)],
      onOpen: (_) => callbacks++,
      onNew: () => callbacks++,
      busy: true,
    ));
    await tester.pump(const Duration(milliseconds: 350));
    final newButton = tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '새 대화'));
    expect(newButton.onPressed, isNull);
    await tester.tap(find.text('최근 대화'));
    await tester.pump();
    final row = tester.widget<ListTile>(find.descendant(
      of: find.byKey(const ValueKey('chat')),
      matching: find.byType(ListTile),
    ));
    expect(row.onTap, isNull);
    expect(callbacks, 0);
  });

  testWidgets('archived chat hides input on a narrow resized screen',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(300, 380);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_app(
      chats: const [],
      onOpen: (_) {},
      onReturn: () {},
      viewingSavedChat: true,
      scale: 2,
    ));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('이전 대화 · 읽기 전용'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
