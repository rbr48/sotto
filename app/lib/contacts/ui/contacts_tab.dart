import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_controller.dart';
import '../../call/call_controller.dart';
import '../../chat/chat_manager.dart';
import '../../chat/chat_store.dart';
import '../../chat/ui/chat_page.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/test_hooks.dart';
import '../../core/ui_kit.dart';
import '../contact_book.dart';
import 'contact_dialogs.dart';

/// Contacts: share your own contact link, add colleagues, call them.
class ContactsTab extends StatelessWidget {
  const ContactsTab({super.key, required this.app, required this.calls});

  final AppController app;
  final CallController calls;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.contacts,
      builder: (context, _) {
        final contacts = app.contacts.contacts;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        AddContactFromLinkDialog(app: app, calls: calls),
                  ),
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('Add contact'),
                ),
                OutlinedButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => ShareContactDialog(app: app, calls: calls),
                  ),
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('Share my contact'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (calls.chat case final chat?)
              _RecentChatsSection(
                chat: chat,
                contacts: app.contacts,
                calls: calls,
              ),
            if (contacts.isEmpty)
              const EmptyState(
                icon: Icons.people_outline,
                title: 'No contacts yet',
                message:
                    'Add colleagues from their contact link, or add someone '
                    'after a call.',
              )
            else ...[
              const SizedBox(height: 8),
              SectionLabel('Contacts · ${contacts.length}'),
              Card(
                child: Column(
                  children: [
                    for (final (index, contact) in contacts.indexed) ...[
                      if (index > 0) const Divider(indent: 72),
                      ListTile(
                        leading: InitialsAvatar(name: contact.name),
                        title: Text(contact.name),
                        subtitle: Text(
                          [
                            if (contact.organisation.isNotEmpty)
                              contact.organisation,
                            contact.verified ? 'Verified' : 'Not verified',
                            if (contact.autoAnswer) 'Auto-answer',
                          ].join(' · '),
                        ),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (_) => ContactDetailsDialog(
                            app: app,
                            calls: calls,
                            contact: contact,
                          ),
                        ),
                        trailing: Wrap(
                          children: [
                            if (calls.chat case final chat?)
                              _ContactChatButton(
                                chat: chat,
                                contactId: contact.identity.id,
                                contactName: contact.name,
                                calls: calls,
                              ),
                            IconButton(
                              tooltip: 'Voice call ${contact.name}',
                              icon: const Icon(Icons.call),
                              onPressed: () => calls.callPeer(
                                contact.identity,
                                video: false,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Video call ${contact.name}',
                              icon: const Icon(Icons.videocam),
                              onPressed: () => calls.callPeer(contact.identity),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Your contact link as text and QR code, plus the plain call link.
class ShareContactDialog extends StatelessWidget {
  const ShareContactDialog({super.key, required this.app, required this.calls});

  final AppController app;
  final CallController calls;

  @override
  Widget build(BuildContext context) {
    final link = calls.contactLink;
    publishForTests('contact-link', link);
    final mono = Theme.of(context).textTheme.bodySmall
        ?.copyWith(fontFamily: 'monospace');
    void copy(String text, String what) {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$what copied')));
    }

    return AlertDialog(
      title: const Text('Share my contact'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Colleagues add you by scanning this code or opening the '
                'link. It holds only your public key; your name is sent from '
                'this app while it is online. Anyone with it can call you '
                'directly, so share it with colleagues, not clients (clients '
                'use guest links).',
              ),
              const SizedBox(height: 16),
              Center(
                child: ColoredBox(
                  color: Colors.white,
                  child: QrImageView(
                    data: link,
                    size: 280,
                    semanticsLabel: 'QR code of your contact link',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(link, maxLines: 3, style: mono),
              if (!app.persistent) ...[
                const SizedBox(height: 12),
                Text(
                  'This browser session keeps nothing: after you close or '
                  'reload the tab, this link stops working.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => copy(link, 'Contact link'),
          child: const Text('Copy contact link'),
        ),
        TextButton(
          onPressed: () => copy(calls.callLink ?? '', 'Call link'),
          child: const Text('Copy call link'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _ContactChatButton extends StatefulWidget {
  const _ContactChatButton({
    required this.chat,
    required this.contactId,
    required this.contactName,
    this.calls,
  });

  final ChatManager chat;
  final String contactId;
  final String contactName;
  final CallController? calls;

  @override
  State<_ContactChatButton> createState() => _ContactChatButtonState();
}

class _ContactChatButtonState extends State<_ContactChatButton> {
  int _unreadCount = 0;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.chat.store.changes.listen((_) => _refresh());
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(_ContactChatButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chat != widget.chat ||
        oldWidget.contactId != widget.contactId) {
      _sub?.cancel();
      _sub = widget.chat.store.changes.listen((_) => _refresh());
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final count = await widget.chat.store.unreadCount(widget.contactId);
    if (mounted) setState(() => _unreadCount = count);
  }

  @override
  Widget build(BuildContext context) {
    final iconWidget = const Icon(Icons.chat_bubble_outline);
    return IconButton(
      tooltip:
          '${AppLocalizations.of(context).chatMessage}: ${widget.contactName}',
      icon: _unreadCount > 0
          ? Badge(label: Text('$_unreadCount'), child: iconWidget)
          : iconWidget,
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(
            chat: widget.chat,
            contactId: widget.contactId,
            name: widget.contactName,
            sendTyping: widget.calls?.sendTyping ?? true,
            sendReadReceipts: widget.calls?.sendReadReceipts ?? true,
          ),
        ),
      ),
    );
  }
}

class _RecentChatsSection extends StatefulWidget {
  const _RecentChatsSection({
    required this.chat,
    required this.contacts,
    this.calls,
  });

  final ChatManager chat;
  final ContactBook contacts;
  final CallController? calls;

  @override
  State<_RecentChatsSection> createState() => _RecentChatsSectionState();
}

class _RecentChatsSectionState extends State<_RecentChatsSection> {
  List<ChatThreadSummary> _summaries = const [];
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.chat.store.changes.listen((_) => _refresh());
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(_RecentChatsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chat != widget.chat) {
      _sub?.cancel();
      _sub = widget.chat.store.changes.listen((_) => _refresh());
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final list = await widget.chat.store.recentChats();
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

  @override
  Widget build(BuildContext context) {
    if (_summaries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel('Recent conversations · ${_summaries.length}'),
        Card(
          child: Column(
            children: [
              for (final (index, summary) in _summaries.indexed) ...[
                if (index > 0) const Divider(indent: 72),
                _buildTile(context, theme, summary),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildTile(
    BuildContext context,
    ThemeData theme,
    ChatThreadSummary summary,
  ) {
    final contact = widget.contacts.contacts
        .where((c) => c.identity.id == summary.contactId)
        .firstOrNull;
    final name =
        contact?.name ??
        (summary.contactId.length > 8
            ? 'Contact ${summary.contactId.substring(0, 8)}'
            : summary.contactId);

    final last = summary.lastMessage;
    return ListTile(
      leading: InitialsAvatar(name: name),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Row(
        children: [
          if (last.outgoing) ...[
            Icon(
              _statusIcon(last.state),
              size: 13,
              color: last.state == ChatState.read
                  ? const Color(0xFF38BDF8)
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              'You: ',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          Expanded(
            child: Text(
              last.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _formatTime(last.ts),
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          if (summary.unreadCount > 0)
            Badge(label: Text('${summary.unreadCount}'))
          else
            const SizedBox(height: 14),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(
            chat: widget.chat,
            contactId: summary.contactId,
            name: name,
            sendTyping: widget.calls?.sendTyping ?? true,
            sendReadReceipts: widget.calls?.sendReadReceipts ?? true,
          ),
        ),
      ),
    );
  }
}
