import 'package:flutter/material.dart';

import '../../contacts/contact_book.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/ui_kit.dart';
import 'chat_tokens.dart';

/// Shows [contacts] in a bottom sheet under [title], and returns the contact
/// the user taps. Returns null if the sheet is dismissed instead.
Future<Contact?> pickContact(
  BuildContext context, {
  required String title,
  required List<Contact> contacts,
}) {
  return showModalBottomSheet<Contact>(
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
                title,
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
                      leading: InitialsAvatar(name: c.name, avatar: c.avatar),
                      title: Text(
                        c.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: c.organisation.isNotEmpty
                          ? Text(c.organisation)
                          : null,
                      trailing: c.verified
                          ? Icon(
                              Icons.verified,
                              color: ChatTokens.of(ctx).verifiedIcon,
                              size: 18,
                              semanticLabel: AppLocalizations.of(ctx)
                                  .chatVerifiedTooltip,
                            )
                          : null,
                      onTap: () => Navigator.pop(ctx, c),
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
