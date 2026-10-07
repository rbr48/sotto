import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

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

  void _showQr(String url, String title) {
    final theme = Theme.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: url,
                  size: 220,
                  version: QrVersions.auto,
                  semanticsLabel: 'QR code of your guest link',
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Scan with a phone camera to join the waiting room.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final personal = controller.personalGuestLink;
    final linkStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      fontSize: 12,
    );

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.link_rounded, color: theme.colorScheme.primary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Guest links',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'Clients join from any browser without an app or account.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.visibility_outlined, size: 14, color: theme.colorScheme.onSecondaryContainer),
                  const SizedBox(width: 6),
                  Text(
                    'Guests see: ${widget.shownAs}',
                    key: const Key('guest-link-name'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (personal != null) ...[
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                padding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.link_rounded, size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SelectableText(personal, maxLines: 1, style: linkStyle),
                    ),
                    IconButton(
                      tooltip: 'Copy personal link',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () => _copy(personal),
                    ),
                    IconButton(
                      tooltip: 'Show QR code',
                      icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                      onPressed: () => _showQr(personal, 'Personal guest link'),
                    ),
                    IconButton(
                      tooltip: 'Replace personal link (the old one stops working)',
                      icon: const Icon(Icons.autorenew_rounded, size: 18),
                      onPressed: controller.rotatePersonalGuestLink,
                    ),
                  ],
                ),
              ),
            ],
            for (final link in controller.oneTimeGuestLinks) ...[
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                padding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.looks_one_outlined, size: 18, color: theme.colorScheme.secondary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SelectableText(link.url, maxLines: 1, style: linkStyle),
                    ),
                    IconButton(
                      tooltip: 'Copy one-time link',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () => _copy(link.url),
                    ),
                    IconButton(
                      tooltip: 'Show QR code',
                      icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                      onPressed: () => _showQr(link.url, 'One-time guest link'),
                    ),
                    IconButton(
                      tooltip: 'Revoke one-time link',
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      onPressed: () => controller.revokeGuestLink(link.record.id),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: controller.createOneTimeGuestLink,
                icon: const Icon(Icons.add_link_rounded, size: 18),
                label: const Text('Create one-time link'),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
