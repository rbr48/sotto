import 'dart:async';

import 'package:flutter/material.dart';

import '../../call/call_controller.dart';
import '../../contacts/contact_book.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/ui_kit.dart';
import '../chat_group.dart';
import '../chat_manager.dart';
import '../chat_store.dart';
import 'chat_page.dart';
import 'message_info_sheet.dart';

/// The starred messages on this device, across every chat, newest first.
///
/// Each chat's messages are read and scanned for the star. That is linear in
/// all messages, which is fine while chats are small. Group chats are in the
/// same scan, so the scan stays the one place the star is found; with groups
/// off ([groupsEnabled]) their messages are left out.
class StarredPage extends StatefulWidget {
  const StarredPage({
    super.key,
    required this.chat,
    this.contacts,
    this.calls,
    this.sendTyping = true,
    this.sendReadReceipts = true,
    this.groupsEnabled = groupsBuildEnabled,
  });

  /// Whether the group screens are on (see [groupsBuildEnabled]). Off, a
  /// starred group message is not listed, so no group is opened from here.
  final bool groupsEnabled;

  final ChatManager chat;

  /// The contacts, for names and avatars. Null: the chats are named by their
  /// Sotto IDs.
  final ContactBook? contacts;

  /// Passed on to the chat a starred message opens.
  final CallController? calls;
  final bool sendTyping;
  final bool sendReadReceipts;

  @override
  State<StarredPage> createState() => _StarredPageState();
}

class _StarredPageState extends State<StarredPage> {
  List<ChatMessage> _starred = const [];

  /// The groups of the starred group messages, by id, for their names.
  Map<String, ChatGroup> _groups = const {};
  bool _loaded = false;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.chat.store.changes.listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final store = widget.chat.store;
    final ids = [
      for (final chat in await store.recentChats()) chat.contactId,
      for (final chat in await store.archivedChats()) chat.contactId,
    ];
    final groups = <String, ChatGroup>{
      if (widget.groupsEnabled)
        for (final group in await store.groups()) group.id: group,
    };
    final found = <ChatMessage>[];
    for (final id in ids) {
      try {
        for (final message in await store.messages(id)) {
          if (message.groupId case final group?
              when !groups.containsKey(group)) {
            continue;
          }
          if (message.starred && !message.deletedForAll) found.add(message);
        }
      } on ChatStoreException {
        // A chat that cannot be read has nothing to show here.
      }
    }
    found.sort((a, b) => b.clockMs.compareTo(a.clockMs));
    if (mounted) {
      setState(() {
        _starred = found;
        _groups = groups;
        _loaded = true;
      });
    }
  }

  Contact? _contactFor(String contactId) =>
      widget.contacts?.contacts.where((c) => c.id == contactId).firstOrNull;

  String _nameFor(AppLocalizations l10n, String contactId) =>
      _groups[contactId]?.name ??
      _contactFor(contactId)?.name ??
      (contactId.length > 8
          ? l10n.chatsUnknownContact(contactId.substring(0, 8))
          : contactId);

  /// Opens the chat the message is in, at that message. The chat opens at the
  /// message only if it is among the messages the chat has loaded; otherwise
  /// it opens at the newest. This page is replaced, so Back returns to where
  /// the user was before.
  void _open(ChatMessage message) {
    final contact = _contactFor(message.contactId);
    final l10n = AppLocalizations.of(context);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(
          chat: widget.chat,
          contactId: message.contactId,
          name: _nameFor(l10n, message.contactId),
          sendTyping: widget.sendTyping,
          sendReadReceipts: widget.sendReadReceipts,
          verified: contact?.verified ?? false,
          calls: widget.calls,
          contacts: widget.contacts,
          avatar: contact?.avatar,
          focusMessageId: message.id,
          groupId: message.groupId,
          groupsEnabled: widget.groupsEnabled,
        ),
      ),
    );
  }

  Future<void> _unstar(ChatMessage message) async {
    await widget.chat.setStarred(message.contactId, message.id, false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.chatStarredMessages)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _starred.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: EmptyState(
                  icon: Icons.star_border,
                  title: l10n.chatStarredEmpty,
                ),
              ),
            )
          : ListView.builder(
              itemCount: _starred.length,
              itemBuilder: (context, index) {
                final message = _starred[index];
                final name = _nameFor(l10n, message.contactId);
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  leading: InitialsAvatar(
                    name: name,
                    avatar: _contactFor(message.contactId)?.avatar,
                    radius: 20,
                  ),
                  title: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        // A voice note shows as "Voice message", not its file name.
                        message.isAttachment && message.voiceNote
                            ? l10n.chatVoiceMessage
                            : message.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        messageWhen(context, message.clockMs),
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    icon: Icon(Icons.star, color: scheme.primary),
                    tooltip: l10n.chatUnstar,
                    onPressed: () => unawaited(_unstar(message)),
                  ),
                  onTap: () => _open(message),
                );
              },
            ),
    );
  }
}
