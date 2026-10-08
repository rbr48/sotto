import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../call/ui/common.dart';
import '../../lock/ui/lock_ui.dart';
import '../../storage/ui/backup_ui.dart';
import '../../core/downloads.dart';
import '../app_controller.dart';
import 'header_downloads_action.dart';

enum _Step { welcome, profile, restore }

/// First start: create an identity (or restore one from a backup), then
/// the name and practice guests will see, and an optional PIN.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.app});

  final AppController app;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  late _Step _step = widget.app.hasIdentity ? _Step.profile : _Step.welcome;
  late final _name = TextEditingController(text: widget.app.suggestedName);
  final _practice = TextEditingController();
  bool _protect = false;
  bool _remember = false;
  bool _busy = false;
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _practice.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _nameError = 'Enter your name.');
      return;
    }
    if (_protect && !await showSetPinDialog(context, widget.app.lock)) return;
    setState(() => _busy = true);
    await widget.app.completeOnboarding(
      name: _name.text,
      practice: _practice.text,
      rememberInBrowser: _remember,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = widget.app;
    return Title(
      title: 'Sotto · Welcome',
      color: theme.colorScheme.primary,
      child: Scaffold(
        appBar: kIsWeb
            ? AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                actions: [
                  HeaderDownloadsAction(app: app),
                  const SizedBox(width: 8),
                ],
              )
            : null,
        body: SafeArea(
          child: Centered(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: SottoWordmark(height: 56)),
                const SizedBox(height: 20),
                const Text(
                  'Private, end-to-end encrypted calls with your clients and '
                  'colleagues. Nothing is stored on our servers.',
                  textAlign: TextAlign.center,
                ),
                if (!app.persistent) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: theme.colorScheme.secondaryContainer,
                    child: const ListTile(
                      leading: Icon(Icons.public),
                      title: Text('This browser forgets you'),
                      subtitle: Text(
                        'This browser forgets everything when you close or '
                        'reload the tab. Turn on Remember me to keep your '
                        'contacts here, or install the Sotto app.\n'
                        'Where it is kept: with Remember me, only in this '
                        'browser on this computer; with the app, only on '
                        'your phone or computer. Always encrypted, never on '
                        'our servers.',
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                ...switch (_step) {
                  _Step.welcome => _welcome(app),
                  _Step.profile => _profile(app),
                  _Step.restore => [
                    Text(
                      'Restore from a backup',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    RestoreBackupForm(app: app),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => setState(() => _step = _Step.welcome),
                      child: const Text('Back'),
                    ),
                  ],
                },
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _welcome(AppController app) => [
    FilledButton.icon(
      onPressed: () => setState(() => _step = _Step.profile),
      icon: const Icon(Icons.person_add_alt),
      label: Text(app.persistent ? 'Create my identity' : 'Start'),
    ),
    if (app.backupsAvailable) ...[
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: () => setState(() => _step = _Step.restore),
        icon: const Icon(Icons.restore),
        label: const Text('Restore from a backup'),
      ),
    ],
    if (kIsWeb) ...[
      const SizedBox(height: 24),
      const Divider(),
      const SizedBox(height: 16),
      Text(
        'Or download the app to keep your contacts and history on your device:',
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: () => launchUrl(
              Downloads.android,
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.android, size: 18),
            label: const Text('Android'),
          ),
          OutlinedButton.icon(
            onPressed: () => launchUrl(
              Downloads.windows,
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.desktop_windows, size: 18),
            label: const Text('Windows'),
          ),
          OutlinedButton.icon(
            onPressed: () => launchUrl(
              Downloads.linux,
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.terminal, size: 18),
            label: const Text('Linux'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Center(
        child: TextButton.icon(
          onPressed: () => launchUrl(
            app.server.web.resolve('downloads.html'),
            mode: LaunchMode.externalApplication,
          ),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('All downloads & checksums'),
        ),
      ),
    ],
  ];

  List<Widget> _profile(AppController app) => [
    Text(
      app.hasIdentity ? 'Welcome back' : 'About you',
      style: Theme.of(context).textTheme.titleLarge,
    ),
    const SizedBox(height: 4),
    Text(
      app.hasIdentity
          ? 'Your identity is kept. Add the name your clients and colleagues '
                'will see.'
          : 'Clients see this on your guest links; colleagues see it on your '
                'contact link. It stays on this device and inside the links.',
    ),
    const SizedBox(height: 16),
    TextField(
      controller: _name,
      autofocus: true,
      textCapitalization: TextCapitalization.words,
      decoration: InputDecoration(
        labelText: 'Your name',
        hintText: 'e.g. Dr Meera Rao',
        errorText: _nameError,
      ),
      onChanged: (_) => setState(() => _nameError = null),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _practice,
      textCapitalization: TextCapitalization.words,
      decoration: const InputDecoration(
        labelText: 'Practice or organisation (optional)',
      ),
    ),
    if (app.canRememberInBrowser && !app.persistent)
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _remember,
        onChanged: (v) => setState(() => _remember = v),
        title: const Text('Remember me on this browser'),
        subtitle: const Text(
          'Keeps your links, contacts and history in this browser, on this '
          'computer only (encrypted, never on our servers). Use it only on '
          'your own computer, not a shared one.',
        ),
      ),
    if (app.persistent || _remember)
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _protect,
        onChanged: (v) => setState(() => _protect = v),
        title: const Text('Protect Sotto with a PIN'),
        subtitle: const Text('Recommended. You can also do this later.'),
      ),
    const SizedBox(height: 16),
    FilledButton(
      onPressed: _busy ? null : _finish,
      child: const Text('Continue'),
    ),
    if (!app.hasIdentity)
      TextButton(
        onPressed: () => setState(() => _step = _Step.welcome),
        child: const Text('Back'),
      ),
  ];
}
