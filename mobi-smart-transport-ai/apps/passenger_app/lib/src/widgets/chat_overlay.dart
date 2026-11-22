import 'described_action.dart';
import 'package:flutter/material.dart';

import '../services/route_chat_history.dart';
import 'chat_message.dart';

export 'chat_message.dart';

/// A floating chat overlay panel that sits on top of the guidance page.
///
/// It shows a scrollable list of [ChatMessage] objects and a text input
/// bar at the bottom. When the user submits a message, [onSendMessage]
/// is called. The parent is responsible for adding the message to
/// [messages] and triggering agent + TTS logic.
class ChatOverlay extends StatefulWidget {
  const ChatOverlay({
    super.key,
    required this.messages,
    required this.onSendMessage,
    required this.onClose,
    required this.isBusy,
    this.historyBusy = false,
    this.canSendMessage = true,
    this.savedChats = const [],
    this.onNewChat,
    this.onOpenSavedChat,
    this.activeChatId,
    this.historyNotice,
    this.viewingSavedChat = false,
    this.onReturnToCurrentChat,
  });

  final List<ChatMessage> messages;
  final Future<void> Function(String message) onSendMessage;
  final VoidCallback onClose;
  final bool isBusy;
  final bool historyBusy;
  final bool canSendMessage;
  final List<SavedRouteChat> savedChats;
  final VoidCallback? onNewChat;
  final ValueChanged<SavedRouteChat>? onOpenSavedChat;
  final String? activeChatId;
  final String? historyNotice;
  final bool viewingSavedChat;
  final VoidCallback? onReturnToCurrentChat;

  @override
  State<ChatOverlay> createState() => _ChatOverlayState();
}

class _ChatOverlayState extends State<ChatOverlay>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _controller;
  late final ScrollController _scrollController;
  late final FocusNode _focusNode;
  late final AnimationController _animationController;
  late final Animation<Offset> _slideAnimation;
  bool _showHistory = false;
  bool get _busy => widget.isBusy || widget.historyBusy;
  bool get _historyEnabled =>
      widget.onNewChat != null || widget.onOpenSavedChat != null;

  void _toggleHistory() {
    _focusNode.unfocus();
    setState(() => _showHistory = !_showHistory);
    if (!_showHistory) _scrollToBottom();
  }

  void _openChat(SavedRouteChat chat) {
    final openChat = widget.onOpenSavedChat;
    if (_busy || openChat == null || chat.id == widget.activeChatId) return;
    _focusNode.unfocus();
    _controller.clear();
    setState(() => _showHistory = false);
    openChat(chat);
    _scrollToBottom();
  }

  void _newChat() {
    final newChat = widget.onNewChat;
    if (_busy || newChat == null) return;
    _focusNode.unfocus();
    setState(() => _showHistory = false);
    newChat();
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _scrollController = ScrollController();
    _focusNode = FocusNode();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));
    _animationController.forward();
  }

  @override
  void didUpdateWidget(covariant ChatOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final chatChanged = widget.activeChatId != oldWidget.activeChatId;
    if (chatChanged) _controller.clear();
    if (widget.messages.length != oldWidget.messages.length || chatChanged) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy || !widget.canSendMessage || _showHistory ||
        widget.viewingSavedChat) {
      return;
    }
    _controller.clear();
    await widget.onSendMessage(text);
  }

  Future<void> _handleClose() async {
    await _animationController.reverse();
    widget.onClose();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final bottomInset = media.viewInsets.bottom;
    final notice = widget.historyNotice;
    final compactHistoryStyle = OutlinedButton.styleFrom(
      minimumSize: const Size(48, 36),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.padded,
    );
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChatHeader(onClose: _handleClose, isBusy: _busy),
        if (_historyEnabled)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              children: [
                if (widget.onNewChat != null)
                  OutlinedButton.icon(
                    style: compactHistoryStyle,
                    onPressed: _busy ? null : _newChat,
                    icon: const Icon(Icons.add_comment_outlined),
                    label: const Text('새 대화'),
                  ),
                if (widget.onOpenSavedChat != null)
                  Semantics(
                    expanded: _showHistory,
                    child: OutlinedButton.icon(
                      style: compactHistoryStyle,
                      onPressed: _toggleHistory,
                      icon: const Icon(Icons.history),
                      label: Text(_showHistory ? '최근 대화 닫기' : '최근 대화'),
                    ),
                  ),
              ],
            ),
          ),
        if (widget.viewingSavedChat)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('이전 대화 · 읽기 전용'),
                  if (widget.onReturnToCurrentChat != null)
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() => _showHistory = false);
                              widget.onReturnToCurrentChat?.call();
                              _scrollToBottom();
                            },
                      child: const Text('현재 대화로 돌아가기'),
                    ),
                ],
              ),
            ),
          ),
        if (notice != null && notice.isNotEmpty)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(notice),
            ),
          ),
        const Divider(height: 1),
      ],
    );

    final composer = _showHistory || widget.viewingSavedChat
        ? null
        : Column(
            children: [
              const Divider(height: 1),
              _ChatInputBar(
                controller: _controller,
                focusNode: _focusNode,
                isBusy: _busy || !widget.canSendMessage,
                onSend: _handleSend,
              ),
            ],
          );
    final sortedChats = [...widget.savedChats]
      ..sort((a, b) {
        final byTime = b.updatedAt.compareTo(a.updatedAt);
        return byTime == 0 ? a.id.compareTo(b.id) : byTime;
      });
    final body = _showHistory
        ? <Widget>[
            if (sortedChats.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                    widget.historyBusy ? '최근 대화를 불러오는 중입니다.' : '저장된 대화가 없습니다.'),
              ),
            for (final (index, chat) in sortedChats.indexed)
              _SavedChatRow(
                key: ValueKey(chat.id),
                number: index + 1,
                chat: chat,
                current: chat.id == widget.activeChatId,
                viewingArchive: widget.viewingSavedChat,
                onOpen: _busy ||
                        chat.id == widget.activeChatId ||
                        widget.onOpenSavedChat == null
                    ? null
                    : () => _openChat(chat),
              ),
          ]
        : <Widget>[
            if (widget.messages.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '채팅으로 에이전트에게 질문해보세요.\n음성으로 답변해 드릴게요!',
                  textAlign: TextAlign.center,
                ),
              ),
            for (final message in widget.messages)
              _ChatBubble(message: message),
          ];

    return SlideTransition(
      position: _slideAnimation,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Material(
            elevation: 16,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            color: colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final scaled = media.textScaler.scale(16);
                final available = constraints.hasBoundedHeight
                    ? constraints.maxHeight
                    : media.size.height;
                final desired =
                    media.size.height * (_historyEnabled ? 0.72 : 0.55);
                final height = desired.clamp(0.0, available).toDouble();
                // Keep controls reachable in landscape, with the keyboard open,
                // or when the system scales text up substantially.
                final scrollAll =
                    height < 330 || scaled > 23 || constraints.maxWidth < 335;
                return SizedBox(
                  height: height,
                  child: scrollAll
                      ? ListView(
                          key: ValueKey(('compact', _showHistory)),
                          padding: EdgeInsets.zero,
                          children: [
                            header,
                            ...body,
                            if (composer != null) composer,
                          ],
                        )
                      : Column(
                          children: [
                            header,
                            Expanded(
                              child: ListView.builder(
                                key: ValueKey(_showHistory),
                                controller:
                                    _showHistory ? null : _scrollController,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                itemCount: body.length,
                                itemBuilder: (context, index) => body[index],
                              ),
                            ),
                            if (composer != null) composer,
                          ],
                        ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SavedChatRow extends StatelessWidget {
  const _SavedChatRow({
    super.key,
    required this.number,
    required this.chat,
    required this.current,
    required this.viewingArchive,
    required this.onOpen,
  });

  final int number;
  final SavedRouteChat chat;
  final bool current;
  final bool viewingArchive;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final timestamp = chat.updatedAt.toLocal();
    final date = '${timestamp.year}년 ${timestamp.month}월 ${timestamp.day}일';
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');

    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outline),
        borderRadius: BorderRadius.circular(12),
      ),
      textColor: scheme.onSurface,
      iconColor: scheme.onSurface,
      selectedColor: scheme.onSurface,
      tileColor: scheme.surface,
      selectedTileColor: scheme.surfaceContainerHighest,
      selected: current,
      title: Text('$number. ${chat.title}'),
      subtitle: Text(
          '$date $hour:$minute${current ? (viewingArchive ? ' · 보고 있는 대화' : ' · 현재 대화') : ''}'),
      onTap: onOpen,
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.onClose, required this.isBusy});

  final VoidCallback onClose;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          // Drag handle
          Expanded(
            child: Row(
              children: [
                Icon(Icons.chat, color: colorScheme.primary, size: 22),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '실시간 채팅',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                if (isBusy) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton.outlined(
            style: IconButton.styleFrom(
              minimumSize: const Size.square(48),
              foregroundColor: colorScheme.onSurface,
              backgroundColor: colorScheme.surface,
              side: BorderSide(color: colorScheme.outline),
            ),
            icon: const Icon(Icons.close),
            onPressed: onClose,
            tooltip: '채팅 닫기',
            iconSize: 22,
          ),
        ],
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 처리 중 '생각' 줄: 답변이 아니라 작업 내용이므로 회색 텍스트로 구분 표시.
    if (message.isThinking) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.more_horiz,
                  size: 14,
                  color: colorScheme.onSurface.withValues(alpha: 0.45)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  message.text,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.5),
                        fontStyle: FontStyle.italic,
                        height: 1.3,
                      ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final isUser = message.isUser;
    final alignment = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final bgColor =
        isUser ? colorScheme.primary : colorScheme.secondaryContainer;
    final textColor =
        isUser ? colorScheme.onPrimary : colorScheme.onSecondaryContainer;
    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(isUser ? 18 : 4),
      bottomRight: Radius.circular(isUser ? 4 : 18),
    );

    final timeStr =
        '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}';

    return Align(
      alignment: alignment,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        margin: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isUser)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.assistant,
                      size: 14,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '에이전트',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.volume_up,
                      size: 12,
                      color: colorScheme.primary.withValues(alpha: 0.6),
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: borderRadius,
              ),
              child: Text(
                message.text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: textColor,
                      height: 1.4,
                    ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
              child: Text(
                timeStr,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.4),
                      fontSize: 10,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatInputBar extends StatelessWidget {
  const _ChatInputBar({
    required this.controller,
    required this.focusNode,
    required this.isBusy,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isBusy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: '메시지를 입력하세요...',
                  hintStyle: TextStyle(
                    color: colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            DescribedAction(
                label: '질문 전송',
                description: '입력한 질문을 보내고 답변을 요청합니다.',
                onActivate: isBusy ? null : onSend,
                child: Material(
                  color: isBusy
                      ? colorScheme.surfaceContainerHighest
                      : colorScheme.primary,
                  borderRadius: BorderRadius.circular(24),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: isBusy ? null : onSend,
                    child: Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      child: isBusy
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            )
                          : Icon(
                              Icons.send_rounded,
                              color: colorScheme.onPrimary,
                              size: 20,
                            ),
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
