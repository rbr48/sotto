import 'package:flutter/material.dart';

import '../../contacts/contact_book.dart';
import '../../core/l10n/app_localizations.dart';
import '../chat_manager.dart';
import 'contact_picker.dart';

/// Forwards [text] to a contact the user picks from [contacts], as a forwarded
/// text. Only contacts are offered, and nothing else is sent. Returns the
/// contact it was sent to, or null when nothing was sent.
Future<Contact?> forwardText(
  BuildContext context, {
  required ChatManager chat,
  required List<Contact> contacts,
  required String text,
}) async {
  final l10n = AppLocalizations.of(context);
  if (contacts.isEmpty) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.chatsAddContactsFirst)));
    return null;
  }
  final contact = await pickContact(
    context,
    title: l10n.chatForwardTitle,
    contacts: contacts,
  );
  if (contact == null) return null;
  await chat.sendText(contact.identity.id, text, forwarded: true);
  return contact;
}
