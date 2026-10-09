import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../call/call_controller.dart';
import '../../core/ui_kit.dart';
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
    final isDark = theme.brightness == Brightness.dark;
    const amber = Color(0xFFF59E0B);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF14141B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: amber.withValues(alpha: 0.6), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: amber.withValues(alpha: isDark ? 0.12 : 0.08),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: amber.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.warning_amber_rounded,
                  color: amber,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Waiting Room',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: amber.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Alert',
                  style: TextStyle(
                    color: amber,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final guest in host.waiting) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '1 guest waiting: ${guest.name} (${TimeOfDay.fromDateTime(guest.since.toLocal()).format(context)})',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: amber,
                      foregroundColor: Colors.black,
                      minimumSize: const Size.fromHeight(46),
                      textStyle: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: controller.call.active
                        ? null
                        : () => controller.admitGuest(guest.knockId),
                    child: const Text('Admit'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PopupMenuButton<String>(
                    tooltip: 'Send quick note',
                    onSelected: (text) => host.message(guest.knockId, text),
                    itemBuilder: (context) => [
                      for (final reply in _quickReplies)
                        PopupMenuItem(value: reply, child: Text(reply)),
                    ],
                    child: Container(
                      height: 46,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: Text(
                        'Quick Note',
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
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
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const IconBadge(icon: Icons.link_rounded),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Guest links',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
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
                color: theme.colorScheme.secondaryContainer.withValues(
                  alpha: 0.45,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.visibility_outlined,
                    size: 14,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
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
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.35,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                padding: const EdgeInsets.only(
                  left: 12,
                  right: 4,
                  top: 4,
                  bottom: 4,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.link_rounded,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SelectableText(
                        personal,
                        maxLines: 1,
                        style: linkStyle,
                      ),
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
                      tooltip:
                          'Replace personal link (the old one stops working)',
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
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.35,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                padding: const EdgeInsets.only(
                  left: 12,
                  right: 4,
                  top: 4,
                  bottom: 4,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.looks_one_outlined,
                      size: 18,
                      color: theme.colorScheme.secondary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SelectableText(
                        link.url,
                        maxLines: 1,
                        style: linkStyle,
                      ),
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
                      onPressed: () =>
                          controller.revokeGuestLink(link.record.id),
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
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
