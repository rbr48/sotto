import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../call/call_controller.dart';
import '../guest_host.dart';

/// Guests knocking on the professional's links.
class WaitingRoom extends StatelessWidget {
  const WaitingRoom({super.key, required this.controller, required this.host});

  final CallController controller;
  final GuestHost host;

  static const _quickReplies = [
    "I'll be with you in 5 minutes.",
    'Running a little late, please wait.',
    "I'm finishing another call. Thanks for waiting.",
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Waiting room (${host.waiting.length})',
                style: theme.textTheme.titleMedium,
              ),
            ),
            for (final guest in host.waiting)
              ListTile(
                leading: Icon(guest.video ? Icons.videocam : Icons.call),
                title: Text(guest.name),
                subtitle: Text(
                  'Waiting since ${TimeOfDay.fromDateTime(guest.since.toLocal()).format(context)}',
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    PopupMenuButton<String>(
                      tooltip: 'Send a message',
                      icon: const Icon(Icons.chat_bubble_outline),
                      onSelected: (text) => host.message(guest.knockId, text),
                      itemBuilder: (context) => [
                        for (final reply in _quickReplies)
                          PopupMenuItem(value: reply, child: Text(reply)),
                      ],
                    ),
                    TextButton(
                      onPressed: () => host.decline(guest.knockId),
                      child: const Text('Decline'),
                    ),
                    FilledButton(
                      onPressed: controller.call.active
                          ? null
                          : () => controller.admitGuest(guest.knockId),
                      child: const Text('Admit'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The professional's guest links: personal (reusable) and one-time.
class GuestLinksCard extends StatefulWidget {
  const GuestLinksCard({
    super.key,
    required this.controller,
    required this.shownAs,
  });

  final CallController controller;

  /// The name on the links (from the profile).
  final String shownAs;

  @override
  State<GuestLinksCard> createState() => _GuestLinksState();
}

class _GuestLinksState extends State<GuestLinksCard> {
  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final personal = controller.personalGuestLink;
    final linkStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Guest links', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Send a link to a client. They join from any browser, without an app '
          'or account, and wait until you admit them.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Text(
          'Guests see: ${widget.shownAs}',
          key: const Key('guest-link-name'),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        if (personal != null)
          Row(
            children: [
              const Icon(Icons.link),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(personal, maxLines: 1, style: linkStyle),
              ),
              IconButton(
                tooltip: 'Copy personal link',
                icon: const Icon(Icons.copy),
                onPressed: () => _copy(personal),
              ),
              IconButton(
                tooltip: 'Replace personal link (the old one stops working)',
                icon: const Icon(Icons.autorenew),
                onPressed: controller.rotatePersonalGuestLink,
              ),
            ],
          ),
        for (final link in controller.oneTimeGuestLinks)
          Row(
            children: [
              const Icon(Icons.looks_one_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(link.url, maxLines: 1, style: linkStyle),
              ),
              IconButton(
                tooltip: 'Copy one-time link',
                icon: const Icon(Icons.copy),
                onPressed: () => _copy(link.url),
              ),
              IconButton(
                tooltip: 'Revoke one-time link',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => controller.revokeGuestLink(link.record.id),
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: controller.createOneTimeGuestLink,
            icon: const Icon(Icons.add_link),
            label: const Text('Create one-time link'),
          ),
        ),
      ],
    );
  }
}
