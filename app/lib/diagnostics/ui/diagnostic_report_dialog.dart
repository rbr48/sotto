import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/version.dart';
import '../../desktop/desktop_integration.dart';
import '../event_log.dart';
import '../report.dart';

/// The report for this app, from its current state and recent events.
String appDiagnosticReport(AppController app, {DateTime? now}) {
  final calls = app.calls;
  final call = calls?.call;
  final prefs = app.desktopPrefs;
  final android = app.android?.status;
  return DiagnosticReport.build(
    version: sottoVersion,
    platform: kIsWeb
        ? 'browser'
        : '${defaultTargetPlatform.name} (${Platform.operatingSystemVersion})',
    facts: {
      'Server':
          '${app.server.relay.host}${app.usesCustomServer ? ' (own server)' : ''}',
      'Relay connection': calls?.relayStatus.name,
      'TURN relay offered': calls == null
          ? null
          : (calls.turnAvailable ? 'yes' : 'no'),
      'Hide my IP address': calls?.hideIp,
      'Data kept on this device': app.persistent
          ? 'yes'
          : 'no (browser session)',
      'Call now': call == null || !call.active
          ? 'none'
          : '${call.phase.name}${call.reconnecting ? ' (reconnecting)' : ''}',
      // During a call its route and quality; otherwise the last call's.
      if (call != null && call.active) ...{
        'Call route': calls?.route?.name,
        'Call quality': calls?.quality?.name,
      } else ...{
        'Last call route': calls?.route?.name,
        'Last call quality': calls?.quality?.name,
      },
      'Sounds': calls?.soundsOn,
      'App lock PIN set': app.lock.hasPin,
      if (android != null) ...{
        'Ring when closed': prefs.ringWhenClosed,
        'Notifications allowed': android.notificationsAllowed,
        'Battery optimization off': android.batteryUnrestricted,
        'Full-screen calls allowed': android.fullScreenAllowed,
      },
      if (isDesktop) ...{
        'Tray available': app.trayAvailable,
        'Keep in tray': prefs.keepInTray,
        'Start at login': prefs.startAtLogin,
      },
      'Update available': app.availableUpdate?.version,
    },
    events: EventLog.instance.entries,
    now: now ?? DateTime.now(),
  );
}

/// Shows the report in full, so the user sees exactly what they would
/// share, with a button to copy it. Nothing is sent by the app.
Future<void> showDiagnosticReport(BuildContext context, AppController app) {
  final report = appDiagnosticReport(app);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Diagnostic report'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Send this to whoever helps you with Sotto. It describes the '
              'connection and recent call states; it contains no names, '
              'contacts, call partners, links or keys.',
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    report,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: report));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Diagnostic report copied')),
              );
              Navigator.pop(context);
            }
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy'),
        ),
      ],
    ),
  );
}
