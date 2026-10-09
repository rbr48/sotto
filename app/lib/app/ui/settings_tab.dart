import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../android/android_integration.dart';
import '../../call/call_controller.dart';
import '../../core/downloads.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/l10n/language.dart';
import '../../core/server_address.dart';
import '../../core/ui_kit.dart';
import '../../core/version.dart';
import '../../desktop/autostart.dart';
import '../../diagnostics/ui/diagnostic_report_dialog.dart';
import '../../desktop/desktop_integration.dart';
import '../../call/ui/common.dart';
import '../../contacts/contact_book.dart';
import '../../history/call_history.dart';
import '../../lock/app_lock.dart';
import '../../lock/ui/lock_ui.dart';
import '../../relay/relay_client.dart';
import '../../storage/ui/backup_ui.dart';
import '../app_controller.dart';

/// The language choice: the device's, or one of the supported languages.
/// Each name is written in its own script, so it can be found by anyone.
class _LanguagePicker extends StatelessWidget {
  const _LanguagePicker();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String name(AppLanguage language) => switch (language) {
      AppLanguage.system => l10n.languageSystem,
      AppLanguage.english => l10n.languageEnglish,
      AppLanguage.bangla => l10n.languageBangla,
      AppLanguage.arabic => l10n.languageArabic,
    };
    return ValueListenableBuilder(
      valueListenable: appLanguage,
      builder: (context, current, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final language in AppLanguage.values)
            ListTile(
              key: ValueKey('language-${language.code}'),
              title: Text(name(language)),
              selected: language == current,
              trailing: language == current
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => chooseAppLanguage(language),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              l10n.languageHelp,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Profile, app lock, auto-answer, privacy, history, devices and backups.
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key, required this.app, required this.calls});

  final AppController app;
  final CallController calls;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([app, app.lock, app.contacts, app.history]),
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(AppLocalizations.of(context).languageSetting, [
          const _LanguagePicker(),
        ]),
        _Section('Profile', [_ProfileForm(app: app)]),
        _Section('App lock', _lock(context)),
        _Section('Auto-answer', _autoAnswer(context)),
        _Section('Sounds', [
          ListenableBuilder(
            listenable: calls,
            builder: (context, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ringtone and chimes'),
              subtitle: const Text(
                'Ring for incoming calls, a ringing tone for your calls, and a '
                'chime when a guest knocks or a call is answered automatically.',
              ),
              value: calls.soundsOn,
              onChanged: calls.setSoundsOn,
            ),
          ),
        ]),
        if (isDesktop)
          _Section('Desktop', [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep running in the tray'),
              subtitle: Text(
                app.trayAvailable
                    ? 'Closing the window keeps Sotto running, so calls and '
                          'waiting guests still reach you. Quit from the tray icon.'
                    : 'No system tray was found on this desktop, so closing '
                          'the window quits Sotto.',
              ),
              value: app.desktopPrefs.keepInTray && app.trayAvailable,
              onChanged: app.trayAvailable
                  ? (v) => app.setDesktopPrefs(
                      app.desktopPrefs.copyWith(keepInTray: v),
                    )
                  : null,
            ),
            if (Autostart.supported)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start Sotto when I log in'),
                subtitle: Text(
                  app.trayAvailable
                      ? 'Sotto starts in the tray, ready for calls and waiting '
                            'guests, without opening a window.'
                      : 'Sotto opens when you log in, ready for calls and '
                            'waiting guests.',
                ),
                value: app.desktopPrefs.startAtLogin,
                onChanged: (v) => app.setDesktopPrefs(
                  app.desktopPrefs.copyWith(startAtLogin: v),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Notifications'),
              subtitle: const Text(
                'When Sotto is in the background: a guest knocks, or a call '
                'comes in.',
              ),
              value: app.desktopPrefs.notifications,
              onChanged: (v) => app.setDesktopPrefs(
                app.desktopPrefs.copyWith(notifications: v),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show names in notifications'),
              subtitle: const Text(
                'Off: notifications only say that someone is waiting, calling '
                'or has written to you. The system may keep notifications in '
                'its history.',
              ),
              value: app.desktopPrefs.showNames,
              onChanged: app.desktopPrefs.notifications
                  ? (v) => app.setDesktopPrefs(
                      app.desktopPrefs.copyWith(showNames: v),
                    )
                  : null,
            ),
          ]),
        if (app.android case final android?)
          _Section('Calls while Sotto is closed', [
            _AndroidBackground(app: app, android: android),
          ]),
        _Section('Privacy', [
          ListenableBuilder(
            listenable: calls,
            builder: (context, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Hide my IP address'),
              subtitle: Text(
                calls.hideIp &&
                        !calls.turnAvailable &&
                        calls.relayStatus == RelayStatus.online
                    ? 'This server has no TURN relay, so calls will fail while this is on.'
                    : 'Route calls through the Sotto server so the other person '
                          'never sees your IP address. Adds a little delay.',
              ),
              value: calls.hideIp,
              onChanged: calls.setHideIp,
            ),
          ),
        ]),
        if (app.canChangeServer)
          _Section('Server', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: Text(app.server.label, key: const Key('server-label')),
              subtitle: Text(
                app.usesCustomServer
                    ? 'Your own server. Calls, guest links and your contact '
                          'link use it.'
                    : 'The Sotto server. You can use your own instead '
                          '(see the self-hosting guide).',
              ),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _changeServer(context),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Use another server'),
                ),
                if (app.usesCustomServer)
                  TextButton(
                    onPressed: () async {
                      if (await _confirmServerChange(context) &&
                          context.mounted) {
                        await app.setServer(null);
                      }
                    },
                    child: const Text('Use the Sotto server'),
                  ),
              ],
            ),
          ]),
        _Section('Call history', [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep call history and notes'),
            trailing: DropdownButton<int?>(
              value: app.history.retentionDays,
              onChanged: app.history.setRetentionDays,
              items: [
                for (final days in CallHistory.retentionChoices)
                  DropdownMenuItem(
                    value: days,
                    child: Text(switch (days) {
                      0 => "Don't keep",
                      null => 'Until I delete them',
                      _ => 'For $days days',
                    }),
                  ),
              ],
            ),
          ),
        ]),
        _Section('Camera, microphone and speaker', [
          DevicePicker(controller: calls, embedded: true),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: app.devices.refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Look for devices again'),
            ),
          ),
        ]),
        if (app.backupsAvailable)
          _Section('Backup', [
            const Text(
              'If this device is lost, a backup is the only way to keep your '
              'identity: colleagues and guest links keep working.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () async {
                    if (await confirmWithPin(
                          context,
                          app.lock,
                          reason: 'Creating a backup',
                        ) &&
                        context.mounted) {
                      await showExportBackupDialog(context, app);
                    }
                  },
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Back up now'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _restore(context),
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore a backup'),
                ),
              ],
            ),
          ]),
        _Section('This device', [
          if (app.canRememberInBrowser)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: app.rememberedInBrowser,
              onChanged: calls.call.active
                  ? null
                  : (on) => on ? app.rememberInBrowser() : _forget(context),
              title: const Text('Remember me on this browser'),
              subtitle: Text(
                app.rememberedInBrowser
                    ? 'Your links, contacts and history are kept in this '
                          'browser, on this computer only (encrypted, never '
                          'on our servers). Turn off to delete them here.'
                    : 'Off: this browser forgets everything when you close '
                          'or reload the tab, and your links stop working. '
                          'Turn on only on your own computer.',
              ),
            ),
          if (calls.ownId case final id?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Your Sotto ID'),
              subtitle: SelectableText(
                id,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => _erase(context),
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('Erase Sotto from this device'),
            ),
          ),
        ]),
        _Section('Help', [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Diagnostic report'),
            subtitle: const Text(
              'When something doesn\'t work: see and copy a report of the '
              'connection and recent call states, without personal data.',
            ),
            onTap: () => showDiagnosticReport(context, app),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy policy'),
            subtitle: const Text('What the server and the app process.'),
            onTap: () => launchUrl(
              app.server.web.resolve('privacy.html'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('Terms of use'),
            onTap: () => launchUrl(
              app.server.web.resolve('terms.html'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download_outlined),
            title: const Text('Download apps'),
            subtitle: const Text('Get Sotto for Android, Windows, and Linux.'),
            onTap: () =>
                launchUrl(Downloads.all, mode: LaunchMode.externalApplication),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.headset_mic_outlined),
            title: const Text('Sotto Live Call Center'),
            subtitle: const Text('Call Sotto support directly in the app'),
            onTap: () => launchUrl(
              Uri.parse(
                'https://call.sottocall.com/#c=n3qJ6HlYC0WI3DU_ixZTW6VaXCTX04zQTw5FjPj20CQ',
              ),
              mode: LaunchMode.externalApplication,
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.support_agent_outlined),
            title: const Text('Support'),
            subtitle: const Text('support@sottocall.com'),
            onTap: () => launchUrl(
              Uri.parse('mailto:support@sottocall.com'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.mail_outline),
            title: const Text('Contact'),
            subtitle: const Text('contact@sottocall.com'),
            onTap: () => launchUrl(
              Uri.parse('mailto:contact@sottocall.com'),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ]),
        _Section('Updates', [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: Text('Sotto $sottoVersion'),
            subtitle: app.availableUpdate != null
                ? Text('Version ${app.availableUpdate!.version} is available.')
                : null,
          ),
          if (app.canCheckUpdates)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Check for updates'),
              subtitle: const Text(
                'Once a day, Sotto asks GitHub for the latest version and '
                'tells you when there is a newer one. GitHub sees your IP '
                'address, nothing else. Sotto never installs anything by '
                'itself.',
              ),
              value: app.desktopPrefs.checkUpdates,
              onChanged: (v) => app.setDesktopPrefs(
                app.desktopPrefs.copyWith(checkUpdates: v),
              ),
            ),
        ]),
      ],
    ),
  );

  List<Widget> _lock(BuildContext context) {
    final lock = app.lock;
    if (!lock.hasPin) {
      return [
        const Text(
          'Lock Sotto with a PIN when you leave it. Needed for auto-answer '
          'and backups.',
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: () => showSetPinDialog(context, lock),
            icon: const Icon(Icons.pin_outlined),
            label: const Text('Set a PIN'),
          ),
        ),
      ];
    }
    return [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Lock after leaving Sotto'),
        trailing: DropdownButton<int>(
          value: AppLock.autoLockChoices.contains(lock.autoLockSeconds)
              ? lock.autoLockSeconds
              : AppLock.defaultAutoLockSeconds,
          onChanged: (v) => lock.setAutoLockSeconds(v!),
          items: [
            for (final seconds in AppLock.autoLockChoices)
              DropdownMenuItem(
                value: seconds,
                child: Text(
                  seconds == 0 ? 'Immediately' : 'After ${seconds ~/ 60} min',
                ),
              ),
          ],
        ),
      ),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.tonalIcon(
            onPressed: lock.lock,
            icon: const Icon(Icons.lock_outline),
            label: const Text('Lock now'),
          ),
          OutlinedButton(
            onPressed: () async {
              if (await confirmWithPin(
                    context,
                    lock,
                    reason: 'Changing the PIN',
                  ) &&
                  context.mounted) {
                await showSetPinDialog(context, lock);
              }
            },
            child: const Text('Change PIN'),
          ),
          OutlinedButton(
            onPressed: () async {
              if (await confirmWithPin(
                context,
                lock,
                reason: 'Removing the PIN turns auto-answer off.',
              )) {
                await app.contacts.setAutoAnswerEnabled(false);
                await lock.removePin();
              }
            },
            child: const Text('Remove PIN'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _autoAnswer(BuildContext context) {
    final book = app.contacts;
    final trusted = book.trusted;
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Auto-answer calls from trusted contacts'),
        subtitle: Text(
          trusted.isEmpty
              ? 'First choose who: open a verified contact and turn on '
                    '"Answer their calls automatically".'
              : 'Calls from ${trusted.map((c) => c.name).join(', ')} ring '
                    'for a moment, then connect by themselves (voice only '
                    'unless you allow video). You can still decline.',
        ),
        value: book.autoAnswerEnabled && trusted.isNotEmpty,
        onChanged: trusted.isEmpty
            ? null
            : (value) async {
                if (await confirmWithPin(
                  context,
                  app.lock,
                  reason: 'Changing auto-answer',
                )) {
                  await book.setAutoAnswerEnabled(value);
                }
              },
      ),
      if (book.autoAnswerEnabled && trusted.isNotEmpty)
        Row(
          children: [
            const Text('Ring first for'),
            Expanded(
              child: Slider(
                value: book.delaySeconds.toDouble(),
                max: ContactBook.maxDelaySeconds.toDouble(),
                divisions: ContactBook.maxDelaySeconds,
                label: '${book.delaySeconds} s',
                onChanged: null,
              ),
            ),
            Text('${book.delaySeconds} s'),
            IconButton(
              tooltip: 'Change the ring time',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _changeDelay(context),
            ),
          ],
        ),
    ];
  }

  Future<void> _changeDelay(BuildContext context) async {
    if (!await confirmWithPin(
          context,
          app.lock,
          reason: 'Changing auto-answer',
        ) ||
        !context.mounted) {
      return;
    }
    var value = app.contacts.delaySeconds;
    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Ring first for'),
          content: Slider(
            value: value.toDouble(),
            max: ContactBook.maxDelaySeconds.toDouble(),
            divisions: ContactBook.maxDelaySeconds,
            label: '$value s',
            onChanged: (v) => setState(() => value = v.round()),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(value),
              child: Text('$value s'),
            ),
          ],
        ),
      ),
    );
    if (chosen != null) await app.contacts.setDelaySeconds(chosen);
  }

  Future<bool> _confirmServerChange(BuildContext context) async {
    if (!await confirmWithPin(
          context,
          app.lock,
          reason: 'Changing the server',
          requirePin: false,
        ) ||
        !context.mounted) {
      return false;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change the server?'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'Guest links and the contact link you already shared point to the '
            'current server, so they stop reaching you. Share new links '
            'afterwards. Your identity and contacts stay the same, but '
            'colleagues must use the same server to call you.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Change server'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _changeServer(BuildContext context) async {
    final chosen = await showDialog<ServerAddress>(
      context: context,
      builder: (_) => const _ServerDialog(),
    );
    if (chosen == null || !context.mounted) return;
    if (await _confirmServerChange(context)) await app.setServer(chosen);
  }

  Future<void> _restore(BuildContext context) async {
    if (!await confirmWithPin(
          context,
          app.lock,
          reason: 'Restoring a backup replaces your identity and data',
        ) ||
        !context.mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore a backup'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'This replaces the identity, contacts, links and history on '
                  'this device with the ones in the backup.',
                ),
                const SizedBox(height: 12),
                RestoreBackupForm(
                  app: app,
                  onRestored: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _forget(BuildContext context) async {
    // Forgetting only removes data, so it needs the PIN only if there is one.
    if (app.lock.hasPin &&
        !await confirmWithPin(
          context,
          app.lock,
          reason: 'Forgetting this browser',
        )) {
      return;
    }
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this browser?'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'Your identity, contacts, history and notes are deleted from this '
            'browser. This tab keeps working until you close or reload it; '
            'then your links stop working.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok ?? false) await app.forgetBrowser();
  }

  Future<void> _erase(BuildContext context) async {
    if (!await confirmWithPin(context, app.lock, reason: 'Erasing Sotto') ||
        !context.mounted) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Erase Sotto from this device?'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'Your identity, contacts, guest links, history and notes are '
            'deleted from this device. Without a backup, your links stop '
            'working for good.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Erase'),
          ),
        ],
      ),
    );
    if (ok ?? false) await app.eraseEverything();
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(title),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ProfileForm extends StatefulWidget {
  const _ProfileForm({required this.app});

  final AppController app;

  @override
  State<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<_ProfileForm> {
  late final _name = TextEditingController(
    text: widget.app.profile?.name ?? '',
  );
  late final _practice = TextEditingController(
    text: widget.app.profile?.practice ?? '',
  );

  @override
  void dispose() {
    _name.dispose();
    _practice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _name,
        decoration: const InputDecoration(labelText: 'Your name'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _practice,
        decoration: const InputDecoration(
          labelText: 'Practice or organisation',
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonal(
          onPressed: () async {
            if (_name.text.trim().isEmpty) return;
            final messenger = ScaffoldMessenger.of(context);
            await widget.app.updateProfile(
              name: _name.text,
              practice: _practice.text,
            );
            messenger.showSnackBar(
              const SnackBar(
                content: Text(
                  'Saved. Guest links and your contact link now show the new name.',
                ),
              ),
            );
          },
          child: const Text('Save profile'),
        ),
      ),
    ],
  );
}

/// Asks for a server address and checks that a Sotto relay answers there.
class _ServerDialog extends StatefulWidget {
  const _ServerDialog();

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  final _address = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final ServerAddress server;
    try {
      server = ServerAddress.parse(_address.text);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final problem = await checkServer(server);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _error = problem;
    });
    if (problem == null) Navigator.of(context).pop(server);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Use another server'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Enter the address of a Sotto server, for example one your '
            'organisation runs with the self-hosting package.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _address,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Server address',
              hintText: 'sotto.example.com',
              errorText: _error,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _check(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _checking ? null : _check,
        child: _checking
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Check and use'),
      ),
    ],
  );
}

/// Android: "Ring even when Sotto is closed", what Android still has to
/// allow for it, and the notification choices.
class _AndroidBackground extends StatelessWidget {
  const _AndroidBackground({required this.app, required this.android});

  final AppController app;
  final AndroidIntegration android;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: android,
    builder: (context, _) {
      final status = android.status;
      final ring = app.desktopPrefs.ringWhenClosed;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ring even when Sotto is closed'),
            subtitle: const Text(
              'Sotto stays connected to your server in the background, with '
              'a quiet notification, so calls and waiting guests ring like a '
              'phone call. Uses a little battery. No push service is used.',
            ),
            value: ring,
            onChanged: (v) => app.setDesktopPrefs(
              app.desktopPrefs.copyWith(ringWhenClosed: v),
            ),
          ),
          if (!status.notificationsAllowed)
            _Fix(
              text:
                  'Notifications are off: calls can\'t ring while Sotto is '
                  'in the background.',
              action: 'Allow notifications',
              onPressed: android.requestNotifications,
            ),
          if (ring && !status.batteryUnrestricted)
            _Fix(
              text:
                  'Battery optimization may stop Sotto while the phone '
                  'sleeps, and calls would no longer ring.',
              action: 'Allow running in the background',
              onPressed: android.requestBatteryExemption,
            ),
          if (!status.fullScreenAllowed)
            _Fix(
              text: 'Calls can\'t ring full screen on the lock screen.',
              action: 'Open settings',
              onPressed: android.openFullScreenSettings,
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Notify me when a guest knocks'),
            subtitle: const Text('While Sotto is in the background.'),
            value: app.desktopPrefs.notifications,
            onChanged: (v) => app.setDesktopPrefs(
              app.desktopPrefs.copyWith(notifications: v),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show names on the ringing screen'),
            subtitle: const Text(
              'Off: it only says that a call or a guest is waiting. Others may '
              'see your lock screen, and Android may keep notifications in '
              'its history. Never shown while Sotto is locked.',
            ),
            value: app.desktopPrefs.showNames,
            onChanged: (v) =>
                app.setDesktopPrefs(app.desktopPrefs.copyWith(showNames: v)),
          ),
        ],
      );
    },
  );
}

/// Something Android has to allow, with the button that opens it.
class _Fix extends StatelessWidget {
  const _Fix({
    required this.text,
    required this.action,
    required this.onPressed,
  });

  final String text;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text),
          const SizedBox(height: 8),
          FilledButton.tonal(onPressed: onPressed, child: Text(action)),
        ],
      ),
    ),
  );
}
