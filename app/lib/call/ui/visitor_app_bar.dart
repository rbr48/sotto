import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/ui/header_downloads_action.dart';
import '../../relay/relay_client.dart';
import 'common.dart';

/// The header of pages opened from a link (calling someone, a guest
/// waiting room): the Sotto logo, which goes to the start page, the app
/// downloads and whether the server is reachable.
class VisitorAppBar extends StatelessWidget implements PreferredSizeWidget {
  const VisitorAppBar({super.key, required this.status, this.home});

  final RelayStatus status;

  /// Where the logo leads; by default this server's start page.
  final Uri? home;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final site = Uri.base.resolve('/');
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return AppBar(
      toolbarHeight: 64,
      automaticallyImplyLeading: false,
      titleSpacing: 12,
      title: Tooltip(
        message: 'Sotto home',
        child: Semantics(
          button: true,
          label: 'Sotto home',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => launchUrl(
              home ?? site,
              // Same tab: the visitor is leaving this page, not opening
              // another one.
              webOnlyWindowName: '_self',
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SottoLogo(size: 34),
                  const SizedBox(width: 8),
                  SottoWordmark(height: narrow ? 22 : 26),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        if (kIsWeb) ...[
          HeaderDownloadsAction(allDownloads: site.resolve('downloads.html')),
          const SizedBox(width: 8),
        ],
        RelayStatusChip(status: status),
      ],
    );
  }
}
