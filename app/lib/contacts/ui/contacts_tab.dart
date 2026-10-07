import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_controller.dart';
import '../../call/call_controller.dart';
import '../../core/test_hooks.dart';
import 'contact_dialogs.dart';

/// Contacts: share your own contact link, add colleagues, call them.
class ContactsTab extends StatelessWidget {
  const ContactsTab({super.key, required this.app, required this.calls});

  final AppController app;
  final CallController calls;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text(
                  'No contacts yet. Add colleagues from their contact link, '
                  'or add someone after a call.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            for (final contact in contacts)
              ListTile(
                leading: ExcludeSemantics(
                  child: CircleAvatar(
                    child: Text(
                      contact.name.isEmpty
                          ? '?'
                          : contact.name[0].toUpperCase(),
                    ),
                  ),
                ),
                title: Text(contact.name),
                subtitle: Text(
                  [
                    if (contact.organisation.isNotEmpty) contact.organisation,
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
                    IconButton(
                      tooltip: 'Voice call ${contact.name}',
                      icon: const Icon(Icons.call),
                      onPressed: () =>
                          calls.callPeer(contact.identity, video: false),
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
    final profile = app.profile;
    final link = calls.contactLink(
      name: profile?.name ?? '',
      organisation: profile?.practice ?? '',
    );
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
                'link. It holds only your public keys and your name. Anyone '
                'with it can call you directly, so share it with colleagues, '
                'not clients (clients use guest links).',
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
