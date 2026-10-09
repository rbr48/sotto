import 'dart:async';

import 'package:file_selector/file_selector.dart';
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
    this.sendTyping = true,
    this.sendReadReceipts = true,
  });

  final ChatManager chat;

  /// The contact's Sotto ID.
  final String contactId;

  /// The contact's name, for the title.
  final String name;

  /// Whether to emit real-time typing indicators.
  final bool sendTyping;

  /// Whether to send read receipts when viewing incoming messages.
  final bool sendReadReceipts;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();

  StreamSubscription<ChatManagerEvent>? _events;
  List<ChatMessage> _messages = const [];

  static const int _pageSize = 50;
  int _loadedCount = _pageSize;
  bool _hasMore = true;
  bool _isLoadingMore = false;

  bool _isSearching = false;
  String _searchQuery = '';

  /// What went wrong with the last connection, shown until dismissed.
  String? _problem;
  bool _sending = false;
  Timer? _typingDebounceTimer;
  Timer? _peerTypingTimer;
  bool _peerIsTyping = false;
  bool _myTypingSent = false;
  Duration? _retention;

  @override
  void initState() {
    super.initState();
    widget.chat.viewing(widget.contactId);
    _events = widget.chat.events.listen(_onEvent);
    _input.addListener(_onInputChanged);
    _scrollController.addListener(_onScroll);
    unawaited(_markAndSendRead());
    unawaited(_load(reset: true));
    unawaited(_loadRetention());
  }

  Future<void> _loadRetention() async {
    final ret = await widget.chat.store.retention(widget.contactId);
    if (mounted) setState(() => _retention = ret);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoadingMore && _hasMore) {
        unawaited(_loadMore());
      }
    }
  }

  Future<void> _markAndSendRead() async {
    final readIds = await widget.chat.store.markAsRead(widget.contactId);
    if (widget.sendReadReceipts && readIds.isNotEmpty) {
      widget.chat.sendReadReceipts(widget.contactId, readIds);
    }
  }

  void _onInputChanged() {
    if (!widget.sendTyping) return;
    final hasText = _input.text.trim().isNotEmpty;
    if (hasText && !_myTypingSent) {
      _myTypingSent = true;
      widget.chat.sendTyping(widget.contactId, true);
    } else if (!hasText && _myTypingSent) {
      _myTypingSent = false;
      widget.chat.sendTyping(widget.contactId, false);
    }
    _typingDebounceTimer?.cancel();
    if (hasText) {
      _typingDebounceTimer = Timer(const Duration(seconds: 3), () {
        if (_myTypingSent) {
          _myTypingSent = false;
          widget.chat.sendTyping(widget.contactId, false);
        }
      });
    }
  }

  @override
  void dispose() {
    if (_myTypingSent) {
      _myTypingSent = false;
      widget.chat.sendTyping(widget.contactId, false);
    }
    _typingDebounceTimer?.cancel();
    _peerTypingTimer?.cancel();
    _input.removeListener(_onInputChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    widget.chat.viewing(null);
    unawaited(_events?.cancel());
    _input.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) _loadedCount = _pageSize;
    final total = await widget.chat.store.messageCount(widget.contactId);
    final messages = await widget.chat.store.messages(
      widget.contactId,
      limit: _loadedCount,
    );
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _hasMore = total > _loadedCount;
    });
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    _isLoadingMore = true;
    _loadedCount += _pageSize;
    final total = await widget.chat.store.messageCount(widget.contactId);
    final messages = await widget.chat.store.messages(
      widget.contactId,
      limit: _loadedCount,
    );
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _hasMore = total > _loadedCount;
      _isLoadingMore = false;
    });
  }

  void _onEvent(ChatManagerEvent event) {
    switch (event) {
      case ChatUpdate(:final contact, :final event)
          when contact == widget.contactId:
        if (event is PeerTyping) {
          _peerTypingTimer?.cancel();
          if (event.typing) {
            setState(() => _peerIsTyping = true);
            _peerTypingTimer = Timer(const Duration(seconds: 4), () {
              if (mounted) setState(() => _peerIsTyping = false);
            });
          } else {
            setState(() => _peerIsTyping = false);
          }
          return;
        }
        unawaited(_markAndSendRead());
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
    if (_myTypingSent) {
      _myTypingSent = false;
      widget.chat.sendTyping(widget.contactId, false);
    }
    _typingDebounceTimer?.cancel();
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

  Future<void> _attachFile() async {
    final l10n = AppLocalizations.of(context);
    try {
      final file = await openFile();
      if (file == null) return;
      if (ChatFrames.isBlockedFileType(file.name)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.chatFileBlocked)));
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > maxFileSizeNative) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.chatFileTooLarge)));
        return;
      }
      await widget.chat.offerFile(
        contact: widget.contactId,
        name: file.name,
        bytes: bytes,
        mime: file.mimeType ?? 'application/octet-stream',
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _acceptFile(ChatMessage message) async {
    final fileId = message.fileId ?? message.id;
    await widget.chat.acceptFile(widget.contactId, fileId);
    await _load();
  }

  Future<void> _declineFile(ChatMessage message) async {
    final fileId = message.fileId ?? message.id;
    await widget.chat.declineFile(widget.contactId, fileId);
    await _load();
  }

  Future<void> _openFile(ChatMessage message) async {
    final path = message.filePath;
    if (path == null) return;
    try {
      await launchUrl(Uri.file(path));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open file ($e)')));
    }
  }

  Future<void> _saveFileAs(ChatMessage message) async {
    final path = message.filePath;
    if (path == null) return;
    try {
      final location = await getSaveLocation(suggestedName: message.fileName);
      if (location == null) return;
      await XFile(path).saveTo(location.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).chatFileReceived)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save file ($e)')));
    }
  }

  Future<void> _retry(ChatMessage message) async {
    await widget.chat.retry(widget.contactId, message.id);
    await _load();
  }

  Future<void> _queue(ChatMessage message) async {
    await widget.chat.queue(widget.contactId, message.id);
    await _load();
  }

  Future<void> _unqueue(ChatMessage message) async {
    await widget.chat.unqueue(widget.contactId, message.id);
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
    unawaited(
      Clipboard.setData(ClipboardData(text: message.fileName ?? message.text)),
    );
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

  Future<void> _chooseRetention(AppLocalizations l10n) async {
    final current = await widget.chat.store.retention(widget.contactId);
    if (!mounted) return;
    final options = [
      (Duration.zero, l10n.chatDisappearingOff),
      (const Duration(hours: 24), l10n.chatDisappearing24h),
      (const Duration(days: 7), l10n.chatDisappearing7d),
      (const Duration(days: 30), l10n.chatDisappearing30d),
    ];
    final selected = await showDialog<Duration>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.chatDisappearingTitle),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              l10n.chatDisappearingDesc,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          RadioGroup<Duration>(
            groupValue: current,
            onChanged: (val) => Navigator.of(context).pop(val),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (dur, label) in options)
                  RadioListTile<Duration>(value: dur, title: Text(label)),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected != null && selected != current) {
      await widget.chat.store.setRetention(widget.contactId, selected);
      if (mounted) setState(() => _retention = selected);
      await _load();
    }
  }

  String _retentionText(Duration d, AppLocalizations l10n) {
    if (d.inHours <= 24) return '24h';
    if (d.inDays <= 7) return '7d';
    return '30d';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final displayed = _searchQuery.isEmpty
        ? _messages
        : _messages
              .where(
                (m) =>
                    m.text.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                    (m.fileName?.toLowerCase().contains(
                          _searchQuery.toLowerCase(),
                        ) ??
                        false),
              )
              .toList();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.chatSearchHint,
                  border: InputBorder.none,
                ),
                onChanged: (q) => setState(() => _searchQuery = q.trim()),
              )
            : Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      InitialsAvatar(name: widget.name, radius: 18),
                      Positioned(
                        right: -1,
                        bottom: -1,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).colorScheme.surface,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.verified,
                              color: Color(0xFF10B981),
                              size: 16,
                            ),
                          ],
                        ),
                        Text(
                          'Active now · E2EE',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
        leading: _isSearching
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _isSearching = false;
                  _searchQuery = '';
                  _searchController.clear();
                }),
              )
            : null,
        actions: [
          if (_isSearching) ...[
            if (_searchQuery.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () => setState(() {
                  _searchQuery = '';
                  _searchController.clear();
                }),
              ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: l10n.chatSearch,
              onPressed: () => setState(() => _isSearching = true),
            ),
            IconButton(
              icon: const Icon(Icons.timer_outlined),
              tooltip: l10n.chatDisappearingTitle,
              onPressed: () => unawaited(_chooseRetention(l10n)),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'disappearing') {
                  unawaited(_chooseRetention(l10n));
                } else if (value == 'delete') {
                  unawaited(_deleteChat(l10n));
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'disappearing',
                  child: Row(
                    children: [
                      const Icon(Icons.timer_outlined, size: 20),
                      const SizedBox(width: 12),
                      Text(l10n.chatDisappearingTitle),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      const Icon(Icons.delete_outline, size: 20),
                      const SizedBox(width: 12),
                      Text(l10n.chatDeleteMenu),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_retention case final r? when r > Duration.zero)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Center(
                  child: InkWell(
                    onTap: () => unawaited(_chooseRetention(l10n)),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.hourglass_top,
                            size: 14,
                            color: Color(0xFFF59E0B),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Disappearing messages: ${_retentionText(r, l10n)} timer active',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
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
                  : displayed.isEmpty
                  ? EmptyState(
                      icon: Icons.search_off,
                      title: l10n.chatSearch,
                      message: l10n.chatSearchNoMatches,
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      itemCount: displayed.length,
                      itemBuilder: (context, index) {
                        final message = displayed[displayed.length - 1 - index];
                        return _Bubble(
                          message: message,
                          contactName: widget.name,
                          l10n: l10n,
                          onRetry: _retry,
                          onQueue: _queue,
                          onUnqueue: _unqueue,
                          onTapUrl: _handleUrlTap,
                          onCopy: () => _copyMessage(message),
                          onDelete: () => _deleteMessage(message),
                          onAccept: () => _acceptFile(message),
                          onDecline: () => _declineFile(message),
                          onOpen: () => _openFile(message),
                          onSaveAs: () => _saveFileAs(message),
                        );
                      },
                    ),
            ),
            if (_peerIsTyping)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.chatTyping(widget.name),
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
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
                  IconButton(
                    tooltip: l10n.chatAttachFile,
                    icon: const Icon(Icons.attach_file),
                    onPressed: _attachFile,
                  ),
                  const SizedBox(width: 4),
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
    required this.onQueue,
    required this.onUnqueue,
    required this.onTapUrl,
    required this.onCopy,
    required this.onDelete,
    required this.onAccept,
    required this.onDecline,
    required this.onOpen,
    required this.onSaveAs,
  });

  final ChatMessage message;

  /// The contact's name, for the offline status text.
  final String contactName;
  final AppLocalizations l10n;
  final Future<void> Function(ChatMessage message) onRetry;
  final Future<void> Function(ChatMessage message) onQueue;
  final Future<void> Function(ChatMessage message) onUnqueue;
  final void Function(String url) onTapUrl;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onOpen;
  final VoidCallback onSaveAs;

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
    final isQueued = outgoing && message.state == ChatState.queued;
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
            color: outgoing ? scheme.primary : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(outgoing ? 18 : 4),
              bottomRight: Radius.circular(outgoing ? 4 : 18),
            ),
            border: outgoing ? null : Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: message.isAttachment
                    ? _FileCard(
                        message: message,
                        outgoing: outgoing,
                        foreground: foreground,
                        l10n: l10n,
                        onAccept: onAccept,
                        onDecline: onDecline,
                        onOpen: onOpen,
                        onSaveAs: onSaveAs,
                      )
                    : _LinkifiedText(
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
              if (outgoing && !message.isAttachment) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _statusIcon(message.state),
                      size: 14,
                      color: message.state == ChatState.read
                          ? const Color(0xFF38BDF8)
                          : foreground.withValues(alpha: 0.8),
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
                    if (notSent) ...[
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: foreground,
                        ),
                        onPressed: () => onRetry(message),
                        child: Text(l10n.chatRetry),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: foreground,
                        ),
                        onPressed: () => onQueue(message),
                        child: Text(l10n.chatQueue),
                      ),
                    ],
                    if (isQueued)
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: foreground,
                        ),
                        onPressed: () => onUnqueue(message),
                        child: Text(l10n.chatCancelQueue),
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
    ChatState.queued => Icons.hourglass_top,
    ChatState.delivered => Icons.done_all,
    ChatState.read => Icons.done_all,
    ChatState.notSent => Icons.error_outline,
    ChatState.received => Icons.done,
  };

  /// A message no session opened for is "offline" (the plan's wording). Other
  /// failures say only "Not sent"; the banner explains them.
  String _statusText(ChatMessage message) => switch (message.state) {
    ChatState.sending => l10n.chatStatusSending,
    ChatState.queued => l10n.chatStatusQueued,
    ChatState.delivered => l10n.chatStatusDelivered,
    ChatState.read => l10n.chatStatusRead,
    ChatState.notSent when message.reason == 'no-answer' =>
      l10n.chatStatusNotSentOffline(contactName),
    ChatState.notSent => l10n.chatStatusNotSent,
    ChatState.received => '',
  };
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.message,
    required this.outgoing,
    required this.foreground,
    required this.l10n,
    required this.onAccept,
    required this.onDecline,
    required this.onOpen,
    required this.onSaveAs,
  });

  final ChatMessage message;
  final bool outgoing;
  final Color foreground;
  final AppLocalizations l10n;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onOpen;
  final VoidCallback onSaveAs;

  IconData _fileIcon(String? mime, String? name) {
    final m = (mime ?? '').toLowerCase();
    final n = (name ?? '').toLowerCase();
    if (m.startsWith('image/') ||
        n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    if (m.startsWith('video/') ||
        n.endsWith('.mp4') ||
        n.endsWith('.mkv') ||
        n.endsWith('.mov')) {
      return Icons.videocam_outlined;
    }
    if (m.startsWith('audio/') ||
        n.endsWith('.mp3') ||
        n.endsWith('.wav') ||
        n.endsWith('.ogg') ||
        n.endsWith('.m4a')) {
      return Icons.audio_file_outlined;
    }
    if (m == 'application/pdf' || n.endsWith('.pdf')) {
      return Icons.picture_as_pdf_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final name = message.fileName ?? message.text;
    final size = message.fileSize != null
        ? _formatFileSize(message.fileSize!)
        : '';
    final status = message.fileStatus ?? (outgoing ? 'completed' : 'offered');
    final icon = _fileIcon(message.fileMime, message.fileName);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: foreground.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: foreground, size: 28),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  if (size.isNotEmpty)
                    Text(
                      size,
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.75),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildStatusContent(context, status),
      ],
    );
  }

  Widget _buildStatusContent(BuildContext context, String status) {
    switch (status) {
      case 'offered':
        if (!outgoing) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onAccept,
                child: Text(l10n.chatFileAccept),
              ),
              const SizedBox(width: 8),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: foreground,
                ),
                onPressed: onDecline,
                child: Text(l10n.chatFileDecline),
              ),
            ],
          );
        }
        return Text(
          l10n.chatFileOffer(message.fileName ?? ''),
          style: TextStyle(
            color: foreground.withValues(alpha: 0.8),
            fontSize: 12,
          ),
        );
      case 'transferring':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              outgoing
                  ? l10n.chatFileUploading(0)
                  : l10n.chatFileDownloading(0),
              style: TextStyle(
                color: foreground.withValues(alpha: 0.8),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 140,
              child: LinearProgressIndicator(
                color: foreground,
                backgroundColor: foreground.withValues(alpha: 0.25),
              ),
            ),
          ],
        );
      case 'completed':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 12,
                    color: Color(0xFF10B981),
                  ),
                  SizedBox(width: 4),
                  Text(
                    '100% · Decrypted in RAM',
                    style: TextStyle(
                      color: Color(0xFF10B981),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            if (!outgoing)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.filePath != null) ...[
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: foreground,
                      ),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(l10n.chatFileOpen),
                      onPressed: onOpen,
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: foreground,
                      ),
                      icon: const Icon(Icons.download, size: 16),
                      label: Text(l10n.chatFileSaveAs),
                      onPressed: onSaveAs,
                    ),
                  ] else
                    Text(
                      l10n.chatFileReceived,
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.8),
                        fontSize: 12,
                      ),
                    ),
                ],
              )
            else
              Text(
                l10n.chatFileSent,
                style: TextStyle(
                  color: foreground.withValues(alpha: 0.8),
                  fontSize: 12,
                ),
              ),
          ],
        );
      case 'declined':
        return Text(
          l10n.chatFileDeclined,
          style: TextStyle(
            color: foreground.withValues(alpha: 0.8),
            fontSize: 12,
            fontStyle: FontStyle.italic,
          ),
        );
      case 'cancelled':
        return Text(
          l10n.chatFileCancelled,
          style: TextStyle(
            color: foreground.withValues(alpha: 0.8),
            fontSize: 12,
            fontStyle: FontStyle.italic,
          ),
        );
      case 'failed':
        return Text(
          l10n.chatFileFailed,
          style: TextStyle(
            color: foreground.withValues(alpha: 0.8),
            fontSize: 12,
            fontStyle: FontStyle.italic,
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
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
