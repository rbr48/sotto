import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';

/// App download links placed at the top-right of the header / AppBar.
///
/// On wider displays, renders direct quick-download pills for Android,
/// Windows, and Linux. On narrow screens, collapses into a compact dropdown
/// menu button.
class HeaderDownloadsAction extends StatelessWidget {
  const HeaderDownloadsAction({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final isWide = width >= 860;

    final androidUrl = app.server.web.resolve('downloads/sotto-android.apk');
    final windowsUrl = app.server.web.resolve(
      'downloads/sotto-windows-x64.zip',
    );
    final linuxUrl = app.server.web.resolve('downloads/sotto-linux-x64.tar.gz');
    final allDownloadsUrl = app.server.web.resolve('downloads.html');

    if (!isWide) {
      return PopupMenuButton<Uri>(
        tooltip: 'Download Sotto apps',
        offset: const Offset(0, 42),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onSelected: (url) =>
            launchUrl(url, mode: LaunchMode.externalApplication),
        itemBuilder: (context) => [
          PopupMenuItem(
            value: androidUrl,
            child: const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.android),
              title: Text('Android (.apk)'),
              subtitle: Text('Direct APK package'),
            ),
          ),
          PopupMenuItem(
            value: windowsUrl,
            child: const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.desktop_windows),
              title: Text('Windows (.zip)'),
              subtitle: Text('64-bit portable archive'),
            ),
          ),
          PopupMenuItem(
            value: linuxUrl,
            child: const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.terminal),
              title: Text('Linux (.tar.gz)'),
              subtitle: Text('64-bit portable archive'),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: allDownloadsUrl,
            child: const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.open_in_new),
              title: Text('All downloads & checksums'),
            ),
          ),
        ],
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.5,
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.file_download_outlined,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 5),
              Text(
                'Get app',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'All downloads & SHA-256 checksums',
            child: InkWell(
              onTap: () => launchUrl(
                allDownloadsUrl,
                mode: LaunchMode.externalApplication,
              ),
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(18),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.file_download_outlined,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'Get app:',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _QuickDownloadButton(
            icon: Icons.android,
            label: 'Android',
            tooltip: 'Download Android APK (sotto-android.apk)',
            onTap: () =>
                launchUrl(androidUrl, mode: LaunchMode.externalApplication),
          ),
          const SizedBox(width: 4),
          _QuickDownloadButton(
            icon: Icons.desktop_windows,
            label: 'Windows',
            tooltip: 'Download Windows 64-bit portable (sotto-windows-x64.zip)',
            onTap: () =>
                launchUrl(windowsUrl, mode: LaunchMode.externalApplication),
          ),
          const SizedBox(width: 4),
          _QuickDownloadButton(
            icon: Icons.terminal,
            label: 'Linux',
            tooltip: 'Download Linux 64-bit portable (sotto-linux-x64.tar.gz)',
            onTap: () =>
                launchUrl(linuxUrl, mode: LaunchMode.externalApplication),
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: 'All downloads & SHA-256 checksums',
            child: InkWell(
              onTap: () => launchUrl(
                allDownloadsUrl,
                mode: LaunchMode.externalApplication,
              ),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Icon(
                  Icons.open_in_new,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _QuickDownloadButton extends StatelessWidget {
  const _QuickDownloadButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
