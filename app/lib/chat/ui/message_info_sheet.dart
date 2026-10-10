import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/app_localizations.dart';
import '../chat_store.dart';

/// Shows when [message] was sent, delivered and read, as a sheet.
Future<void> showMessageInfo(BuildContext context, ChatMessage message) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => MessageInfoSheet(message: message),
    );

/// The times this device knows for [message]. Sent is the message's own time,
/// which every message has. Delivered and read are shown only when this device
/// recorded them, so a row is absent rather than blank.
class MessageInfoSheet extends StatelessWidget {
  const MessageInfoSheet({super.key, required this.message});

  final ChatMessage message;

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
      child: Padding(
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
                      _formatWhen(context, row.at),
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The date and time, in the app's language and the device's clock style.
  static String _formatWhen(BuildContext context, int ms) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final when = DateTime.fromMillisecondsSinceEpoch(ms);
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(when),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return '${DateFormat.yMMMd(locale).format(when)}, $time';
  }
}
