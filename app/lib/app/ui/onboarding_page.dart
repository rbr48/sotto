import 'package:flutter/material.dart';

import '../../call/ui/common.dart';
import '../../lock/ui/lock_ui.dart';
import '../../storage/ui/backup_ui.dart';
import '../app_controller.dart';

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
        body: SafeArea(
          child: Centered(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: SottoLogo(size: 88)),
                const SizedBox(height: 12),
                Text(
                  'Sotto',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
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
                      title: Text('Browser session'),
                      subtitle: Text(
                        'Nothing is kept after you close this tab. Install '
                        'the Sotto app to keep your contacts and history.',
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
    if (app.persistent)
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
