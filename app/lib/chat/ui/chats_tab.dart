import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../call/call_controller.dart';
import '../../chat/chat_store.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/ui_kit.dart';
import 'chat_page.dart';

/// The dedicated Chats tab: full conversation inbox, search, unread filters,
/// and direct confidential message threading.
class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key, required this.app, required this.calls});

  final AppController app;
  final CallController calls;

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  List<ChatThreadSummary> _summaries = const [];
  StreamSubscription<void>? _sub;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  int _selectedFilter = 0; // 0 = All, 1 = Unread

  @override
  void initState() {
    super.initState();
    _initSub();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void didUpdateWidget(ChatsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.calls.chat != widget.calls.chat) {
      _sub?.cancel();
      _initSub();
    }
  }

  void _initSub() {
    final chat = widget.calls.chat;
    if (chat != null) {
      _sub = chat.store.changes.listen((_) => _refresh());
      unawaited(_refresh());
    }
  }

  void _onSearchChanged() {
    setState(() => _searchQuery = _searchController.text.trim().toLowerCase());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final chat = widget.calls.chat;
    if (chat == null) return;
    final list = await chat.store.recentChats();
    if (mounted) setState(() => _summaries = list);
  }

  String _formatTime(int ts) {
    final date = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    if (now.year == date.year &&
        now.month == date.month &&
        now.day == date.day) {
      final hour = date.hour.toString().padLeft(2, '0');
      final minute = date.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    }
    final diff = now.difference(date);
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[date.weekday - 1];
    }
    return '${date.month}/${date.day}';
  }

  IconData _statusIcon(ChatState state) => switch (state) {
    ChatState.sending => Icons.schedule,
    ChatState.queued => Icons.hourglass_top,
    ChatState.delivered => Icons.done_all,
    ChatState.read => Icons.done_all,
    ChatState.notSent => Icons.error_outline,
    ChatState.received => Icons.done,
  };

  void _startNewChat() {
    final contacts = widget.app.contacts.contacts;
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add contacts from the Contacts tab first.'),
        ),
      );
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'New conversation',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: contacts.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final c = contacts[index];
                      return ListTile(
                        leading: InitialsAvatar(name: c.name),
                        title: Text(
                          c.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: c.organisation.isNotEmpty
                            ? Text(c.organisation)
                            : null,
                        trailing: c.verified
                            ? const Icon(
                                Icons.verified,
                                color: Color(0xFF10B981),
                                size: 18,
                              )
                            : null,
                        onTap: () {
                          Navigator.pop(ctx);
                          _openChat(
                            c.identity.id,
                            c.name,
                            verified: c.verified,
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openChat(String contactId, String name, {bool verified = false}) {
    final chat = widget.calls.chat;
    if (chat == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(
          chat: chat,
          contactId: contactId,
          name: name,
          sendTyping: widget.calls.sendTyping,
          sendReadReceipts: widget.calls.sendReadReceipts,
          verified: verified,
          calls: widget.calls,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chat = widget.calls.chat;

    if (chat == null) {
      return const Center(child: CircularProgressIndicator());
    }

    var list = _summaries;
    if (_selectedFilter == 1) {
      list = list.where((s) => s.unreadCount > 0).toList();
    }
    if (_searchQuery.isNotEmpty) {
      list = list.where((s) {
        final contact = widget.app.contacts.contacts
            .where((c) => c.identity.id == s.contactId)
            .firstOrNull;
        final name = contact?.name ?? s.contactId;
        return name.toLowerCase().contains(_searchQuery) ||
            s.lastMessage.text.toLowerCase().contains(_searchQuery);
      }).toList();
    }

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startNewChat,
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('New chat'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
        children: [
          // Search & Filter Header
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search conversations…',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          // Filter Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: Text('All (${_summaries.length})'),
                  selected: _selectedFilter == 0,
                  onSelected: (selected) {
                    if (selected) setState(() => _selectedFilter = 0);
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Unread'),
                      if (_summaries
                          .where((s) => s.unreadCount > 0)
                          .isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_summaries.fold<int>(0, (sum, s) => sum + s.unreadCount)}',
                            style: TextStyle(
                              color: scheme.onPrimary,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  selected: _selectedFilter == 1,
                  onSelected: (selected) {
                    if (selected) setState(() => _selectedFilter = 1);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Conversation List or Empty State
          if (_summaries.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: EmptyState(
                icon: Icons.chat_bubble_outline,
                title: 'No conversations yet',
                message:
                    'Messages are end-to-end encrypted. They go directly '
                    'between your devices, or sealed through the relay, which '
                    'holds them for at most a minute and cannot read them.',
              ),
            )
          else if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Text(
                  'No matching conversations',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          else
            Card(
              child: Column(
                children: [
                  for (final (index, summary) in list.indexed) ...[
                    if (index > 0) const Divider(indent: 72),
                    _buildConversationTile(context, theme, summary),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildConversationTile(
    BuildContext context,
    ThemeData theme,
    ChatThreadSummary summary,
  ) {
    final scheme = theme.colorScheme;
    final contact = widget.app.contacts.contacts
        .where((c) => c.identity.id == summary.contactId)
        .firstOrNull;
    final name =
        contact?.name ??
        (summary.contactId.length > 8
            ? 'Contact ${summary.contactId.substring(0, 8)}'
            : summary.contactId);
    final last = summary.lastMessage;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          InitialsAvatar(name: name, radius: 24),
          if (contact?.verified ?? false)
            const Positioned(
              right: -2,
              bottom: -2,
              child: Icon(Icons.verified, color: Color(0xFF10B981), size: 16),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: summary.unreadCount > 0
                    ? FontWeight.bold
                    : FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatTime(last.ts),
            style: TextStyle(
              fontSize: 12,
              color: summary.unreadCount > 0
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
              fontWeight: summary.unreadCount > 0
                  ? FontWeight.bold
                  : FontWeight.normal,
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            if (last.outgoing) ...[
              Icon(
                _statusIcon(last.state),
                size: 14,
                color: last.state == ChatState.read
                    ? const Color(0xFF7C6EE6)
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                'You: ',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            Expanded(
              child: Text(
                // A voice note shows as "Voice message", not its file name.
                last.isAttachment && last.voiceNote
                    ? AppLocalizations.of(context).chatVoiceMessage
                    : last.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: summary.unreadCount > 0
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                  fontWeight: summary.unreadCount > 0
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
              ),
            ),
            if (summary.unreadCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${summary.unreadCount}',
                  style: TextStyle(
                    color: scheme.onPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      onTap: () => _openChat(
        summary.contactId,
        name,
        verified: contact?.verified ?? false,
      ),
    );
  }
}
