/// A single message in the chat conversation.
class ChatMessage {
  const ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.source = 'chat',
    this.kind = 'message',
  });

  final String text;
  final bool isUser;
  final DateTime timestamp;

  /// 발화 경로: 'chat'(채팅 입력) 또는 'voice'(음성 인식).
  final String source;

  /// 'message'(일반 발화/답변) 또는 'thinking'(처리 중 회색 생각줄).
  final String kind;

  bool get isThinking => kind == 'thinking';
}
