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
  const VisitorAppBar({super.key, required this.status, this.home, this.title});

  final RelayStatus status;

  /// What the page is about (e.g. "Call with Dr Rao"), beside the logo on
  /// wider screens; phones show it in the page itself.
  final String? title;

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
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _homeButton(site, narrow),
          if (title case final title? when !narrow) ...[
            Container(
              width: 1,
              height: 28,
              margin: const EdgeInsets.symmetric(horizontal: 14),
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            Flexible(
              // Its own node: not merged with the home button's label.
              child: Semantics(
                container: true,
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (kIsWeb) ...[
          HeaderDownloadsAction(),
          const SizedBox(width: 8),
        ],
        RelayStatusChip(status: status),
      ],
    );
  }

  Widget _homeButton(Uri site, bool narrow) => Tooltip(
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
  );
}
