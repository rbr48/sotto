import 'package:flutter/material.dart';

import '../../call/call_controller.dart';
import '../../call/ui/common.dart';
import '../../contacts/contact_book.dart';
import '../../history/call_history.dart';
import '../../lock/app_lock.dart';
import '../../lock/ui/lock_ui.dart';
import '../../relay/relay_client.dart';
import '../../storage/ui/backup_ui.dart';
import '../app_controller.dart';

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
        _Section('Profile', [_ProfileForm(app: app)]),
        _Section('App lock', _lock(context)),
        _Section('Auto-answer', _autoAnswer(context)),
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
          DevicePicker(controller: calls),
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

  Future<void> _erase(BuildContext context) async {
    if (!await confirmWithPin(context, app.lock, reason: 'Erasing Sotto') ||
        !context.mounted) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Erase Sotto from this device?'),
        content: const Text(
          'Your identity, contacts, guest links, history and notes are '
          'deleted from this device. Without a backup, your links stop '
          'working for good.',
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
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...children,
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
