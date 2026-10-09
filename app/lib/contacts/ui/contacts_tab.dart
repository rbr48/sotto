import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_controller.dart';
import '../../call/call_controller.dart';
import '../../chat/ui/chat_page.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/test_hooks.dart';
import '../../core/ui_kit.dart';
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
                              IconButton(
                                tooltip:
                                    '${AppLocalizations.of(context).chatMessage}: '
                                    '${contact.name}',
                                icon: const Icon(Icons.chat_bubble_outline),
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => ChatPage(
                                      chat: chat,
                                      contactId: contact.identity.id,
                                      name: contact.name,
                                    ),
                                  ),
                                ),
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
