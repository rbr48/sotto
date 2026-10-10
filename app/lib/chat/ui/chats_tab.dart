import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/app_controller.dart';
import '../../call/call_controller.dart';
import '../../chat/chat_store.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/ui_kit.dart';
import 'chat_page.dart';
import 'chat_tokens.dart';
import 'contact_picker.dart';

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

  /// The time of the last message: the time today, "Yesterday", the
  /// weekday within a week, else the date, all in the app's language.
  String _formatTime(BuildContext context, int ts) {
    final date = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final locale = Localizations.localeOf(context).toLanguageTag();
    switch (chatDayLabel(day: date, now: now)) {
      case ChatDayLabel.today:
        return MaterialLocalizations.of(context).formatTimeOfDay(
          TimeOfDay.fromDateTime(date),
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
        );
      case ChatDayLabel.yesterday:
        return AppLocalizations.of(context).chatDayYesterday;
      case ChatDayLabel.other:
        if (now.difference(date).inDays < 7) {
          return DateFormat.E(locale).format(date);
        }
        return DateFormat.Md(locale).format(date);
    }
  }

  IconData _statusIcon(ChatState state) => switch (state) {
    ChatState.sending => Icons.schedule,
    ChatState.queued => Icons.hourglass_top,
    // One tick for delivered, two for read: the shape tells them apart.
    ChatState.delivered => Icons.done,
    ChatState.read => Icons.done_all,
    ChatState.notSent => Icons.error_outline,
    ChatState.received => Icons.done,
  };

  Future<void> _startNewChat() async {
    final contacts = widget.app.contacts.contacts;
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).chatsAddContactsFirst),
        ),
      );
      return;
    }

    final contact = await pickContact(
      context,
      title: AppLocalizations.of(context).chatsNewConversation,
      contacts: contacts,
    );
    if (contact == null || !mounted) return;
    _openChat(
      contact.identity.id,
      contact.name,
      verified: contact.verified,
      avatar: contact.avatar,
    );
  }

  void _openChat(
    String contactId,
    String name, {
    bool verified = false,
    String? avatar,
  }) {
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
          contacts: widget.app.contacts,
          avatar: avatar,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chat = widget.calls.chat;
    final l10n = AppLocalizations.of(context);

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
        label: Text(l10n.chatsNewChat),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
        children: [
          // Search & Filter Header
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: l10n.chatsSearchHint,
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
                  label: Text(l10n.chatsFilterAll(_summaries.length)),
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
                      Text(l10n.chatsFilterUnread),
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
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: EmptyState(
                icon: Icons.chat_bubble_outline,
                title: l10n.chatsEmptyTitle,
                message: l10n.chatDirectNote,
              ),
            )
          else if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Text(
                  l10n.chatsNoMatches,
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
    final l10n = AppLocalizations.of(context);
    final tokens = ChatTokens.of(context);
    final name =
        contact?.name ??
        (summary.contactId.length > 8
            ? l10n.chatsUnknownContact(summary.contactId.substring(0, 8))
            : summary.contactId);
    final last = summary.lastMessage;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          InitialsAvatar(name: name, avatar: contact?.avatar, radius: 24),
          if (contact?.verified ?? false)
            PositionedDirectional(
              end: -2,
              bottom: -2,
              child: Icon(
                Icons.verified,
                color: tokens.verifiedIcon,
                size: 16,
                semanticLabel: l10n.chatVerifiedTooltip,
              ),
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
            _formatTime(context, last.ts),
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
                    ? tokens.readTick
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                l10n.chatsYouPrefix,
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
                    ? l10n.chatVoiceMessage
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
        avatar: contact?.avatar,
      ),
    );
  }
}
