import 'package:flutter/material.dart';

import '../../core/l10n/app_localizations.dart';
import '../chat_frames.dart';
import '../chat_store.dart';

/// The actions a message's menu offers. The context menu (secondary tap) and
/// the action sheet (long press) both list [messageActions], so they cannot
/// drift apart.
enum MessageAction {
  react,
  reply,
  forward,
  copy,
  edit,
  deleteForEveryone,
  deleteForMe,
}

/// Whether [message] can be edited at [now]: your own text, sent no more than
/// [editWindow] before [now], and not deleted. The window runs from the
/// message's own time to [now], with no allowance for clock skew, as the
/// manager checks it.
bool canEdit(ChatMessage message, DateTime now) =>
    message.outgoing &&
    !message.deletedForAll &&
    !message.isAttachment &&
    ChatFrames.withinWindow(message.ts, now.millisecondsSinceEpoch, editWindow);

/// Whether [message] can be deleted for everyone at [now]: your own text, sent
/// no more than [deleteWindow] before [now], and not already deleted.
bool canDeleteForEveryone(ChatMessage message, DateTime now) =>
    message.outgoing &&
    !message.deletedForAll &&
    !message.isAttachment &&
    ChatFrames.withinWindow(
      message.ts,
      now.millisecondsSinceEpoch,
      deleteWindow,
    );

/// The items of the menu for [message] at [now], in order. Delete for me is
/// always offered, as it has been since the chat began.
List<MessageAction> messageActions(ChatMessage message, DateTime now) {
  final live = !message.deletedForAll;
  return [
    if (live) MessageAction.react,
    if (live) MessageAction.reply,
    if (live && !message.isAttachment) MessageAction.forward,
    if (live) MessageAction.copy,
    if (canEdit(message, now)) MessageAction.edit,
    if (canDeleteForEveryone(message, now)) MessageAction.deleteForEveryone,
    MessageAction.deleteForMe,
  ];
}

/// The icon, label and colour of [action].
({IconData icon, String label, bool destructive}) _presentation(
  MessageAction action,
  AppLocalizations l10n,
) => switch (action) {
  MessageAction.react => (
    icon: Icons.add_reaction_outlined,
    label: l10n.chatReact,
    destructive: false,
  ),
  MessageAction.reply => (
    icon: Icons.reply,
    label: l10n.chatReply,
    destructive: false,
  ),
  MessageAction.forward => (
    icon: Icons.forward,
    label: l10n.chatForward,
    destructive: false,
  ),
  MessageAction.copy => (
    icon: Icons.copy,
    label: l10n.chatCopy,
    destructive: false,
  ),
  MessageAction.edit => (
    icon: Icons.edit_outlined,
    label: l10n.chatEdit,
    destructive: false,
  ),
  MessageAction.deleteForEveryone => (
    icon: Icons.delete_sweep_outlined,
    label: l10n.chatDeleteForEveryone,
    destructive: true,
  ),
  MessageAction.deleteForMe => (
    icon: Icons.delete_outline,
    label: l10n.chatDeleteMessage,
    destructive: true,
  ),
};

/// Shows the menu of [message] at [position], for a secondary tap. Calls
/// [onSelected] with the action chosen; nothing is called when dismissed.
Future<void> showMessageContextMenu(
  BuildContext context, {
  required Offset position,
  required ChatMessage message,
  required DateTime now,
  required ValueChanged<MessageAction> onSelected,
}) async {
  final l10n = AppLocalizations.of(context);
  final theme = Theme.of(context);
  final selected = await showMenu<MessageAction>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    ),
    items: [
      for (final action in messageActions(message, now))
        PopupMenuItem(
          value: action,
          child: _menuRow(theme, _presentation(action, l10n)),
        ),
    ],
  );
  if (selected != null) onSelected(selected);
}

/// Shows the menu of [message] as a sheet, for a long press. Calls
/// [onSelected] with the action tapped.
void showMessageSheet(
  BuildContext context, {
  required ChatMessage message,
  required DateTime now,
  required ValueChanged<MessageAction> onSelected,
}) {
  final l10n = AppLocalizations.of(context);
  showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in messageActions(message, now))
            _sheetItem(sheetContext, action, l10n, onSelected),
        ],
      ),
    ),
  );
}

Widget _menuRow(
  ThemeData theme,
  ({IconData icon, String label, bool destructive}) item,
) {
  final color = item.destructive ? theme.colorScheme.error : null;
  return Row(
    children: [
      Icon(item.icon, size: 18, color: color),
      const SizedBox(width: 8),
      Text(item.label, style: TextStyle(color: color)),
    ],
  );
}

Widget _sheetItem(
  BuildContext sheetContext,
  MessageAction action,
  AppLocalizations l10n,
  ValueChanged<MessageAction> onSelected,
) {
  final item = _presentation(action, l10n);
  final color = item.destructive
      ? Theme.of(sheetContext).colorScheme.error
      : null;
  return ListTile(
    leading: Icon(item.icon, color: color),
    title: Text(item.label, style: TextStyle(color: color)),
    onTap: () {
      Navigator.of(sheetContext).pop();
      onSelected(action);
    },
  );
}
