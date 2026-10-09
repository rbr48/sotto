import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/ui_kit.dart';
import '../chat_frames.dart';
import '../chat_manager.dart';
import '../chat_session.dart';
import '../chat_store.dart';

/// One chat with a contact: the messages, a box to write in, and what
/// happened when the connection was made.
///
/// Messages go directly between the two devices, so the page says when a
/// message could not go, and offers to send it again.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.chat,
    required this.contactId,
    required this.name,
  });

  final ChatManager chat;

  /// The contact's Sotto ID.
  final String contactId;

  /// The contact's name, for the title.
  final String name;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  StreamSubscription<ChatManagerEvent>? _events;
  List<ChatMessage> _messages = const [];

  /// What went wrong with the last connection, shown until dismissed.
  String? _problem;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    widget.chat.viewing(widget.contactId);
    _events = widget.chat.events.listen(_onEvent);
    unawaited(widget.chat.store.markAsRead(widget.contactId));
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.chat.viewing(null);
    unawaited(_events?.cancel());
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final messages = await widget.chat.store.messages(widget.contactId);
    if (!mounted) return;
    setState(() => _messages = messages);
  }

  void _onEvent(ChatManagerEvent event) {
    switch (event) {
      case ChatUpdate(:final contact, :final event)
          when contact == widget.contactId:
        unawaited(widget.chat.store.markAsRead(widget.contactId));
        // An ordinary end (bye, closed, idle) needs no explanation.
        if (event is SessionEnded && !_ordinaryEnd(event.reason)) {
          setState(() => _problem = event.reason);
        }
        unawaited(_load());
      case ChatOpenFailure(:final contact, :final reason)
          when contact == widget.contactId:
        setState(() => _problem = reason);
        unawaited(_load());
      default:
        break;
    }
  }

  static bool _ordinaryEnd(String reason) =>
      reason == 'bye' || reason == 'closed' || reason == 'idle';

  String _problemText(AppLocalizations l10n, String reason) => switch (reason) {
    'no-relay' => l10n.chatFailNoRelay,
    'not-contact' || 'declined' => l10n.chatFailDeclined,
    _ => l10n.chatFailConnection,
  };

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.chat.sendText(widget.contactId, text);
      _input.clear();
    } on ArgumentError {
      // Too long, or not a contact any more: the text stays in the box.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    await _load();
  }

  Future<void> _retry(ChatMessage message) async {
    await widget.chat.retry(widget.contactId, message.id);
    await _load();
  }

  Future<void> _handleUrlTap(String url) async {
    var target = url;
    if (target.startsWith('www.')) {
      target = 'https://$target';
    }
    final uri = Uri.tryParse(target);
    if (uri == null) return;

    if (uri.scheme == 'mailto') {
      try {
        await launchUrl(uri);
      } catch (_) {}
      return;
    }

    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.chatOpenLinkTitle),
        content: Text(l10n.chatOpenLinkBody(url)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.chatCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.chatOpenLink),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  void _copyMessage(ChatMessage message) {
    unawaited(Clipboard.setData(ClipboardData(text: message.text)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).chatCopied),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.chatDeleteMessageTitle),
        content: Text(l10n.chatDeleteMessageBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.chatCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.chatDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.chat.store.deleteMessage(widget.contactId, message.id);
    await _load();
  }

  Future<void> _deleteChat(AppLocalizations l10n) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.chatDeleteTitle),
        content: Text(l10n.chatDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.chatCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.chatDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.chat.close(widget.contactId);
    await widget.chat.store.deleteChat(widget.contactId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (_) => _deleteChat(l10n),
            itemBuilder: (context) => [
              PopupMenuItem(value: 'delete', child: Text(l10n.chatDeleteMenu)),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_problem case final problem?)
              _ProblemBanner(
                text: _problemText(l10n, problem),
                dismiss: l10n.chatDismiss,
                onDismiss: () => setState(() => _problem = null),
              ),
            Expanded(
              child: _messages.isEmpty
                  ? EmptyState(
                      icon: Icons.chat_bubble_outline,
                      title: l10n.chatMessage,
                      message: l10n.chatEmptyHint,
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      itemBuilder: (context, index) {
                        final message = _messages[_messages.length - 1 - index];
                        return _Bubble(
                          message: message,
                          contactName: widget.name,
                          l10n: l10n,
                          onRetry: _retry,
                          onTapUrl: _handleUrlTap,
                          onCopy: () => _copyMessage(message),
                          onDelete: () => _deleteMessage(message),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                l10n.chatDirectNote,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: maxTextChars,
                      buildCounter: (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(hintText: l10n.chatWriteHint),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: l10n.chatSend,
                    icon: const Icon(Icons.send),
                    onPressed: _send,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProblemBanner extends StatelessWidget {
  const _ProblemBanner({
    required this.text,
    required this.dismiss,
    required this.onDismiss,
  });

  final String text;
  final String dismiss;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onDismiss, child: Text(dismiss)),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.contactName,
    required this.l10n,
    required this.onRetry,
    required this.onTapUrl,
    required this.onCopy,
    required this.onDelete,
  });

  final ChatMessage message;

  /// The contact's name, for the offline status text.
  final String contactName;
  final AppLocalizations l10n;
  final Future<void> Function(ChatMessage message) onRetry;
  final void Function(String url) onTapUrl;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  void _showContextMenu(BuildContext context, Offset position) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'copy',
          child: Row(
            children: [
              const Icon(Icons.copy, size: 18),
              const SizedBox(width: 8),
              Text(l10n.chatCopy),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(
                Icons.delete_outline,
                size: 18,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.chatDeleteMessage,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ),
        ),
      ],
    );
    if (selected == 'copy') onCopy();
    if (selected == 'delete') onDelete();
  }

  void _showActionSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(l10n.chatCopy),
              onTap: () {
                Navigator.of(context).pop();
                onCopy();
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                l10n.chatDeleteMessage,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.of(context).pop();
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final outgoing = message.outgoing;
    final notSent = outgoing && message.state == ChatState.notSent;
    final background = outgoing ? scheme.primary : scheme.surfaceContainerHigh;
    final foreground = outgoing ? scheme.onPrimary : scheme.onSurface;
    final linkColor = outgoing ? scheme.onPrimary : scheme.primary;

    return Align(
      alignment: outgoing
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: GestureDetector(
        onSecondaryTapUp: (details) =>
            _showContextMenu(context, details.globalPosition),
        onLongPress: () => _showActionSheet(context),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
          ),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: _LinkifiedText(
                  text: message.text,
                  style: TextStyle(color: foreground),
                  linkStyle: TextStyle(
                    color: linkColor,
                    decoration: TextDecoration.underline,
                    fontWeight: FontWeight.w600,
                  ),
                  onTapUrl: onTapUrl,
                ),
              ),
              if (outgoing) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _statusIcon(message.state),
                      size: 14,
                      color: foreground.withValues(alpha: 0.8),
                    ),
                    const SizedBox(width: 4),
                    // Long names wrap here, so the Retry button stays on the bubble.
                    Flexible(
                      child: Text(
                        _statusText(message),
                        style: TextStyle(
                          fontSize: 12,
                          color: foreground.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                    if (notSent)
                      TextButton(
                        // The label takes the bubble's text colour, because the
                        // theme default is the bubble colour itself.
                        style: TextButton.styleFrom(
                          foregroundColor: foreground,
                        ),
                        onPressed: () => onRetry(message),
                        child: Text(l10n.chatRetry),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _statusIcon(ChatState state) => switch (state) {
    ChatState.sending => Icons.schedule,
    ChatState.delivered => Icons.done_all,
    ChatState.notSent => Icons.error_outline,
    ChatState.received => Icons.done,
  };

  /// A message no session opened for is "offline" (the plan's wording). Other
  /// failures say only "Not sent"; the banner explains them.
  String _statusText(ChatMessage message) => switch (message.state) {
    ChatState.sending => l10n.chatStatusSending,
    ChatState.delivered => l10n.chatStatusDelivered,
    ChatState.notSent when message.reason == 'no-answer' =>
      l10n.chatStatusNotSentOffline(contactName),
    ChatState.notSent => l10n.chatStatusNotSent,
    ChatState.received => '',
  };
}

class _LinkifiedText extends StatefulWidget {
  const _LinkifiedText({
    required this.text,
    required this.style,
    required this.linkStyle,
    required this.onTapUrl,
  });

  final String text;
  final TextStyle style;
  final TextStyle linkStyle;
  final void Function(String url) onTapUrl;

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  static final _urlRegex = RegExp(
    r'(https?:\/\/[^\s<>"{}|\\^`]+|mailto:[^\s<>"{}|\\^`]+|www\.[^\s<>"{}|\\^`]+)',
    caseSensitive: false,
  );
  static final _trailingPunctuation = RegExp(r'[.,;:)!?]+$');

  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  List<InlineSpan> _buildSpans() {
    _clearRecognizers();
    final matches = _urlRegex.allMatches(widget.text).toList();
    if (matches.isEmpty) {
      return [TextSpan(text: widget.text, style: widget.style)];
    }

    final spans = <InlineSpan>[];
    var lastIndex = 0;

    for (final match in matches) {
      if (match.start > lastIndex) {
        spans.add(
          TextSpan(
            text: widget.text.substring(lastIndex, match.start),
            style: widget.style,
          ),
        );
      }

      var rawUrl = match.group(0)!;
      var punctuation = '';
      final pMatch = _trailingPunctuation.firstMatch(rawUrl);
      if (pMatch != null) {
        punctuation = rawUrl.substring(pMatch.start);
        rawUrl = rawUrl.substring(0, pMatch.start);
      }

      final url = rawUrl;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onTapUrl(url);
      _recognizers.add(recognizer);

      spans.add(
        TextSpan(text: url, style: widget.linkStyle, recognizer: recognizer),
      );

      if (punctuation.isNotEmpty) {
        spans.add(TextSpan(text: punctuation, style: widget.style));
      }

      lastIndex = match.end;
    }

    if (lastIndex < widget.text.length) {
      spans.add(
        TextSpan(text: widget.text.substring(lastIndex), style: widget.style),
      );
    }

    return spans;
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(TextSpan(children: _buildSpans()));
  }
}
