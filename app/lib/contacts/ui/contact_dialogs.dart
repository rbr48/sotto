import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../call/call_controller.dart';
import '../../call/ui/common.dart';
import '../../chat/image_metadata.dart';
import '../../core/ui_kit.dart';
import '../../crypto/identity.dart';
import '../../lock/ui/lock_ui.dart';
import '../contact_book.dart';
import '../contact_link.dart';
import '../profile_exchange.dart';

/// Adds someone as a contact: name, organisation, and whether the user
/// compared the safety number with them.
class AddContactDialog extends StatefulWidget {
  const AddContactDialog({
    super.key,
    required this.safetyNumber,
    required this.onSave,
    this.name = '',
    this.organisation = '',
  });

  final String? safetyNumber;
  final String name;
  final String organisation;
  final Future<void> Function(String name, String organisation, bool verified)
  onSave;

  @override
  State<AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<AddContactDialog> {
  late final _name = TextEditingController(text: widget.name);
  late final _organisation = TextEditingController(text: widget.organisation);
  bool _compared = false;

  @override
  void dispose() {
    _name.dispose();
    _organisation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add to contacts'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.name.isEmpty,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _organisation,
              decoration: const InputDecoration(
                labelText: 'Organisation (optional)',
              ),
            ),
            if (widget.safetyNumber case final number?) ...[
              const SizedBox(height: 16),
              const Text(
                'Compare this safety number with them, in person or on a '
                'call. If it matches, nobody is intercepting your calls.',
              ),
              const SizedBox(height: 8),
              SafetyNumberBadge(number: number),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _compared,
                onChanged: (v) => setState(() => _compared = v ?? false),
                title: const Text('I compared this safety number with them'),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () async {
          final navigator = Navigator.of(context);
          await widget.onSave(_name.text, _organisation.text, _compared);
          navigator.pop();
        },
        child: const Text('Save contact'),
      ),
    ],
  );
}

/// Adds a contact from a pasted contact link, call link or code.
class AddContactFromLinkDialog extends StatefulWidget {
  const AddContactFromLinkDialog({
    super.key,
    required this.app,
    required this.calls,
  });

  final AppController app;
  final CallController calls;

  @override
  State<AddContactFromLinkDialog> createState() =>
      _AddContactFromLinkDialogState();
}

class _AddContactFromLinkDialogState extends State<AddContactFromLinkDialog> {
  final _link = TextEditingController();
  String? _error;
  ContactInvite? _invite;
  bool _busy = false;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    ContactInvite? invite;
    try {
      invite = await widget.calls.resolveLink(_link.text);
      if (invite.identity.id == widget.calls.ownId) {
        invite = null;
        error = 'That is your own link.';
      }
    } on InvalidIdentityException catch (e) {
      error = e.message == 'that is your own call link'
          ? 'That is your own link.'
          : 'That is not a valid Sotto contact link or call link.';
    } on ProfileUnavailableException {
      error =
          'Their Sotto did not answer. It needs to be open and online to '
          'share their details; try again later, or ask for a new link.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _invite = invite;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final invite = _invite;
    if (invite != null) {
      return AddContactDialog(
        safetyNumber: widget.calls.safetyNumberWith(invite.identity),
        name: invite.name ?? '',
        organisation: invite.organisation ?? '',
        onSave: (name, organisation, verified) => widget.app.contacts.add(
          invite.identity,
          name: name.trim().isEmpty ? 'Contact' : name,
          organisation: organisation,
          verified: verified,
          avatar: invite.avatar,
        ),
      );
    }
    return AlertDialog(
      title: const Text('Add a contact'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Paste the contact link a colleague sent you (or their call '
              'link).',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _link,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Contact link',
                errorText: _error,
              ),
              onSubmitted: (_) => _read(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _read,
          child: Text(_busy ? 'Looking up…' : 'Next'),
        ),
      ],
    );
  }
}

/// A contact's details: call, verify, auto-answer, edit, delete.
class ContactDetailsDialog extends StatefulWidget {
  const ContactDetailsDialog({
    super.key,
    required this.app,
    required this.calls,
    required this.contact,
  });

  final AppController app;
  final CallController calls;
  final Contact contact;

  @override
  State<ContactDetailsDialog> createState() => _ContactDetailsDialogState();
}

class _ContactDetailsDialogState extends State<ContactDetailsDialog> {
  late final _name = TextEditingController(text: widget.contact.name);
  late final _organisation = TextEditingController(
    text: widget.contact.organisation,
  );

  @override
  void dispose() {
    _name.dispose();
    _organisation.dispose();
    super.dispose();
  }

  ContactBook get _book => widget.app.contacts;
  Contact get _contact => _book.find(widget.contact.identity) ?? widget.contact;

  Future<void> _setAutoAnswer({bool? enabled, bool? video}) async {
    final ok = await confirmWithPin(
      context,
      widget.app.lock,
      reason: 'Changing auto-answer',
    );
    if (!ok) return;
    await _book.update(
      _contact.copyWith(autoAnswer: enabled, autoAnswerVideo: video),
    );
  }

  Future<void> _call(bool video) async {
    Navigator.of(context).pop();
    await widget.calls.callPeer(_contact.identity, video: video);
  }

  Future<void> _pickAvatar() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Images',
            extensions: ['jpg', 'jpeg', 'png', 'webp'],
            mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
          ),
        ],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > 500 * 1024) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Avatar image must be under 500 KB')),
        );
        return;
      }
      final clean = ImageMetadata.clean(bytes, file.mimeType ?? 'image/jpeg');
      final b64 = 'data:image/jpeg;base64,${base64Encode(clean)}';
      await _book.setAvatar(_contact.identity, b64);
    } catch (_) {}
  }

  Future<void> _removeAvatar() async {
    await _book.setAvatar(_contact.identity, null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _book,
    builder: (context, _) {
      final contact = _contact;
      return AlertDialog(
        title: Row(
          children: [
            InitialsAvatar(name: contact.name, avatar: contact.avatar, radius: 22),
            const SizedBox(width: 12),
            Expanded(child: Text(contact.label)),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Stack(
                    children: [
                      InitialsAvatar(
                        name: contact.name,
                        avatar: contact.avatar,
                        radius: 44,
                      ),
                      Positioned(
                        right: -4,
                        bottom: -4,
                        child: Material(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: _pickAvatar,
                            child: const Padding(
                              padding: EdgeInsets.all(8.0),
                              child: Icon(Icons.photo_camera, size: 20),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (contact.avatar != null) ...[
                  const SizedBox(height: 4),
                  Center(
                    child: TextButton.icon(
                      onPressed: _removeAvatar,
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Remove photo'),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _call(true),
                      icon: const Icon(Icons.videocam),
                      label: const Text('Video call'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _call(false),
                      icon: const Icon(Icons.call),
                      label: const Text('Voice call'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name'),
                  onSubmitted: (_) => _saveNames(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _organisation,
                  decoration: const InputDecoration(labelText: 'Organisation'),
                  onSubmitted: (_) => _saveNames(),
                ),
                const SizedBox(height: 16),
                if (widget.calls.safetyNumberWith(contact.identity)
                    case final number?)
                  SafetyNumberBadge(number: number),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: contact.verified,
                  onChanged: (v) =>
                      _book.update(contact.copyWith(verified: v ?? false)),
                  title: const Text('I compared this safety number with them'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: contact.autoAnswer,
                  onChanged: contact.verified
                      ? (v) => _setAutoAnswer(enabled: v)
                      : null,
                  title: const Text('Answer their calls automatically'),
                  subtitle: Text(
                    contact.verified
                        ? 'Only while auto-answer is on in Settings.'
                        : 'Compare the safety number first.',
                  ),
                ),
                if (contact.autoAnswer)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: contact.autoAnswerVideo,
                    onChanged: (v) => _setAutoAnswer(video: v),
                    title: const Text('Allow video when auto-answering'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              await _book.remove(contact.identity);
              navigator.pop();
            },
            child: const Text('Delete contact'),
          ),
          FilledButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              await _saveNames();
              navigator.pop();
            },
            child: const Text('Done'),
          ),
        ],
      );
    },
  );

  Future<void> _saveNames() => _book.update(
    _contact.copyWith(
      name: _name.text.trim().isEmpty ? _contact.name : _name.text.trim(),
      organisation: _organisation.text.trim(),
    ),
  );
}
