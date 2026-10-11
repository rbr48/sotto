import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/app_localizations.dart';
import '../chat_store.dart';

/// Shows when [message] was sent, delivered and read, as a sheet. For your
/// message in a group, [members] lists where each member's copy stands.
Future<void> showMessageInfo(
  BuildContext context,
  ChatMessage message, {
  List<({String name, String state})> members = const [],
}) => showModalBottomSheet<void>(
  context: context,
  builder: (_) => MessageInfoSheet(message: message, members: members),
);

/// The date and time [ms] names, in the app's language and the device's clock
/// style. Used for the times in the info sheet and in the starred list.
String messageWhen(BuildContext context, int ms) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  final when = DateTime.fromMillisecondsSinceEpoch(ms);
  final time = MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(when),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  return '${DateFormat.yMMMd(locale).format(when)}, $time';
}

/// The times this device knows for [message]. Sent is the message's own time,
/// which every message has. Delivered and read are shown only when this device
/// recorded them, so a row is absent rather than blank.
///
/// A group message is acknowledged by each member on its own, so for your
/// group message [members] lists each member with the state of its copy.
class MessageInfoSheet extends StatelessWidget {
  const MessageInfoSheet({
    super.key,
    required this.message,
    this.members = const [],
  });

  final ChatMessage message;

  /// Each member of the group and the state of its copy, in words. Empty for
  /// a one-to-one message, and for a group message by someone else.
  final List<({String name, String state})> members;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final rows = [
      (label: l10n.chatInfoSent, at: message.ts),
      if (message.deliveredAt case final at?)
        (label: l10n.chatStatusDelivered, at: at),
      if (message.readAt case final at?) (label: l10n.chatStatusRead, at: at),
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.chatMessageInfo, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(child: Text(row.label)),
                    const SizedBox(width: 16),
                    Text(
                      messageWhen(context, row.at),
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            if (members.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(l10n.groupMembersTitle, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final member in members)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(child: Text(member.name)),
                      const SizedBox(width: 16),
                      Text(
                        member.state,
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
