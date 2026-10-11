import 'dart:async';

import 'package:flutter/material.dart';

import '../../contacts/contact_book.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/ui_kit.dart';
import '../chat_group.dart';
import '../chat_groups.dart';
import '../chat_manager.dart';

/// Makes a new group: a name, and two or three contacts to invite (D24).
///
/// The name is required and at most [maxGroupNameChars] characters once
/// cleaned; it cannot be changed later (D12). Creating calls the group
/// manager, which invites each contact chosen. The page closes with the new
/// group, or with nothing when it is left.
class GroupCreatePage extends StatefulWidget {
  const GroupCreatePage({
    super.key,
    required this.chat,
    required this.contacts,
  });

  final ChatManager chat;

  /// The contacts that can be invited. Only contacts can be.
  final List<Contact> contacts;

  @override
  State<GroupCreatePage> createState() => _GroupCreatePageState();
}

class _GroupCreatePageState extends State<GroupCreatePage> {
  final _name = TextEditingController();
  final _chosen = <String>{};
  String? _nameError;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _toggle(Contact contact, bool selected) {
    setState(() {
      if (selected && _chosen.length < maxInviteOthers) {
        _chosen.add(contact.identity.id);
      } else if (!selected) {
        _chosen.remove(contact.identity.id);
      }
    });
  }

  /// The error for the name as typed, or null when it can be used.
  String? _checkName(AppLocalizations l10n) {
    final cleaned = ChatGroups.cleanName(_name.text);
    if (cleaned.isEmpty) return l10n.groupNameRequired;
    if (cleaned.runes.length > maxGroupNameChars) {
      return l10n.groupNameTooLong(maxGroupNameChars);
    }
    return null;
  }

  Future<void> _create() async {
    final l10n = AppLocalizations.of(context);
    final error = _checkName(l10n);
    setState(() => _nameError = error);
    if (error != null || _chosen.length < minInviteOthers || _busy) return;
    setState(() => _busy = true);
    final ChatGroup group;
    try {
      group = await widget.chat.groups.create(
        name: _name.text,
        // In the order the contacts are listed, as the user saw them.
        invitees: [
          for (final c in widget.contacts)
            if (_chosen.contains(c.identity.id)) c.identity.id,
        ],
      );
    } on ArgumentError {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.groupCreateFailed)));
      return;
    }
    if (mounted) Navigator.of(context).pop(group);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final full = _chosen.length >= maxInviteOthers;
    final ready = _chosen.length >= minInviteOthers && !_busy;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.groupCreateTitle)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                children: [
                  TextField(
                    controller: _name,
                    maxLength: maxGroupNameChars,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: l10n.groupNameLabel,
                      errorText: _nameError,
                    ),
                    onChanged: (_) {
                      if (_nameError != null) {
                        setState(() => _nameError = null);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.groupMembersTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.contacts.length < minInviteOthers
                        ? l10n.groupNeedTwoContacts
                        : l10n.groupMembersHint,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.groupMembersChosen(_chosen.length, maxInviteOthers),
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  for (final contact in widget.contacts)
                    CheckboxListTile(
                      value: _chosen.contains(contact.identity.id),
                      // Past the limit, the rest cannot be chosen (D24).
                      onChanged: full && !_chosen.contains(contact.identity.id)
                          ? null
                          : (v) => _toggle(contact, v ?? false),
                      secondary: InitialsAvatar(
                        name: contact.name,
                        avatar: contact.avatar,
                      ),
                      title: Text(
                        contact.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: ready ? () => unawaited(_create()) : null,
                  child: Text(l10n.groupCreate),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
