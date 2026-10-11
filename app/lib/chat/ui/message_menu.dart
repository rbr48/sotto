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
  star,
  info,
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
/// always offered, as it has been since the chat began. Star and info stay on
/// this device, and are not offered for a message deleted for everyone.
///
/// In a group ([group]), a reply quotes only your own message (D25), so Reply
/// is offered on yours alone. A group you are no longer in is [readOnly]: its
/// history stays, but nothing that would be sent to the members is offered.
List<MessageAction> messageActions(
  ChatMessage message,
  DateTime now, {
  bool group = false,
  bool readOnly = false,
}) {
  final live = !message.deletedForAll;
  final canSend = !readOnly;
  return [
    if (live && canSend) MessageAction.react,
    if (live && canSend && (!group || message.outgoing)) MessageAction.reply,
    if (live && !message.isAttachment) MessageAction.forward,
    if (live) MessageAction.copy,
    if (live) MessageAction.star,
    if (live) MessageAction.info,
    if (canSend && canEdit(message, now)) MessageAction.edit,
    if (canSend && canDeleteForEveryone(message, now))
      MessageAction.deleteForEveryone,
    MessageAction.deleteForMe,
  ];
}

/// The icon, label and colour of [action] for [message].
({IconData icon, String label, bool destructive}) _presentation(
  MessageAction action,
  AppLocalizations l10n,
  ChatMessage message,
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
  MessageAction.star => (
    icon: message.starred ? Icons.star : Icons.star_border,
    label: message.starred ? l10n.chatUnstar : l10n.chatStar,
    destructive: false,
  ),
  MessageAction.info => (
    icon: Icons.info_outline,
    label: l10n.chatMessageInfo,
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
/// [group] and [readOnly] are as in [messageActions].
Future<void> showMessageContextMenu(
  BuildContext context, {
  required Offset position,
  required ChatMessage message,
  required DateTime now,
  required ValueChanged<MessageAction> onSelected,
  bool group = false,
  bool readOnly = false,
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
      for (final action in messageActions(
        message,
        now,
        group: group,
        readOnly: readOnly,
      ))
        PopupMenuItem(
          value: action,
          child: _menuRow(theme, _presentation(action, l10n, message)),
        ),
    ],
  );
  if (selected != null) onSelected(selected);
}

/// Shows the menu of [message] as a sheet, for a long press. Calls
/// [onSelected] with the action tapped. [group] and [readOnly] are as in
/// [messageActions].
void showMessageSheet(
  BuildContext context, {
  required ChatMessage message,
  required DateTime now,
  required ValueChanged<MessageAction> onSelected,
  bool group = false,
  bool readOnly = false,
}) {
  final l10n = AppLocalizations.of(context);
  showModalBottomSheet<void>(
    context: context,
    // The menu now has up to nine items. A sheet that takes only part of the
    // height would show about six, so the sheet may take the whole height and
    // the items still scroll on a small screen.
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final action in messageActions(
            message,
            now,
            group: group,
            readOnly: readOnly,
          ))
            _sheetItem(sheetContext, action, l10n, message, onSelected),
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
  ChatMessage message,
  ValueChanged<MessageAction> onSelected,
) {
  final item = _presentation(action, l10n, message);
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
