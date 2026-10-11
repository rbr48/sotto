import 'dart:async';

import 'package:flutter/material.dart';

import '../../contacts/contact_book.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/ui_kit.dart';
import '../chat_group.dart';
import '../chat_groups.dart';
import '../chat_manager.dart';
import 'group_ui.dart';

/// Shows [group] as a sheet: its members and where each stands, and Leave
/// group. Changes go through the group manager of [chat].
Future<void> showGroupInfo(
  BuildContext context, {
  required ChatManager chat,
  required ChatGroup group,
  required List<Contact> contacts,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => GroupInfoSheet(chat: chat, group: group, contacts: contacts),
);

/// The members of a group with their status on this device, and Leave group.
///
/// Each device keeps its own table of the members, so what this sheet shows
/// is this device's view: a member who is no longer a contact here is "Not
/// reachable", even when the others still reach it. A member who declined or
/// let the invite run out can be invited again by anyone still in the group.
class GroupInfoSheet extends StatelessWidget {
  const GroupInfoSheet({
    super.key,
    required this.chat,
    required this.group,
    required this.contacts,
  });

  final ChatManager chat;
  final ChatGroup group;

  /// The contacts, for the members' names.
  final List<Contact> contacts;

  Future<void> _leave(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.groupLeaveTitle),
        content: Text(l10n.groupLeaveBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.chatCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.groupLeave),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await chat.groups.leave(group.id);
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _inviteAgain(BuildContext context, String memberId) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    try {
      await chat.groups.invite(group.id, memberId);
    } on ArgumentError {
      messenger.showSnackBar(SnackBar(content: Text(l10n.groupCreateFailed)));
      return;
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final active = ChatGroups.isActive(group);
    // This device first, then the others in the order they were invited.
    final members = [
      ...group.members.where((m) => m.id == group.selfId),
      ...group.members.where((m) => m.id != group.selfId),
    ];
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 0, 16),
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 4),
            child: Text(
              group.name,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 8),
            child: Text(
              l10n.groupMemberCount(groupMemberCount(group)),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          for (final member in members)
            _memberTile(context, l10n, theme, member, active),
          if (active) ...[
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.logout, color: theme.colorScheme.error),
              title: Text(
                l10n.groupLeave,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              onTap: () => unawaited(_leave(context)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _memberTile(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
    GroupMember member,
    bool active,
  ) {
    final self = member.id == group.selfId;
    final name = self
        ? l10n.groupMemberYou
        : groupMemberName(l10n, contacts, member.id);
    final status = groupMemberStatus(group, member, chat.isContact);
    final canInvite =
        active &&
        !self &&
        chat.isContact(member.id) &&
        (member.state == MemberState.declined ||
            member.state == MemberState.expired);
    return ListTile(
      leading: InitialsAvatar(name: name),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(groupMemberStatusText(l10n, status)),
      trailing: canInvite
          ? TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => unawaited(_inviteAgain(context, member.id)),
              child: Text(l10n.groupInviteAgain),
            )
          : null,
    );
  }
}
