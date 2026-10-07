import 'package:flutter/material.dart';

import '../../call/ui/call_screen.dart';
import '../../call/ui/common.dart';
import '../../desktop/desktop_integration.dart';
import '../../lock/ui/lock_ui.dart';
import '../app_controller.dart';
import 'home_shell.dart';
import 'onboarding_page.dart';

/// Chooses the screen for the professional's app: onboarding, the lock,
/// a call, or the home screen. Also tells the app lock when the app goes
/// to the background.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key, required this.app});

  final AppController app;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> with WidgetsBindingObserver {
  AppController get _app => widget.app;
  DesktopIntegration? _desktop;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isDesktop) _desktop = DesktopIntegration(_app)..start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _desktop?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _desktop?.inFront = state == AppLifecycleState.resumed;
    if (_app.stage != AppStage.ready) return;
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _app.lock.left();
      case AppLifecycleState.resumed:
        _app.lock.returned();
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _app,
    builder: (context, _) => switch (_app.stage) {
      AppStage.loading => const _Titled(
        label: 'Starting…',
        child: Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      AppStage.failed => _Titled(
        label: 'Error',
        child: Scaffold(
          body: Centered(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Sotto could not start: ${_app.error}'),
                if (_app.keystoreMissing) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Without the keystore, Sotto can still be used for this '
                    'session, but your identity, contacts and history are '
                    'not saved.',
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _app.startTemporarySession,
                    child: const Text('Continue without saving'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      AppStage.vaultProblem => _Titled(
        label: 'Storage problem',
        child: _VaultProblem(app: _app),
      ),
      AppStage.onboarding => OnboardingPage(app: _app),
      AppStage.ready => _ready(),
    },
  );

  bool _covered = false;

  /// A call or the lock replaces the home screen; dialogs opened from it
  /// (contact details, share, history…) must not stay on top: they would
  /// hide the Accept button, or show data while locked.
  void _closeDialogsWhenCovered(BuildContext context, bool covered) {
    if (covered && !_covered) {
      final navigator = Navigator.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) navigator.popUntil((route) => route.isFirst);
      });
    }
    _covered = covered;
  }

  Widget _ready() {
    final calls = _app.calls!;
    return ListenableBuilder(
      listenable: Listenable.merge([
        calls,
        _app.lock,
        _app.contacts,
        _app.history,
        _app.devices,
      ]),
      builder: (context, _) {
        final call = calls.call;
        _closeDialogsWhenCovered(context, call.active || _app.lock.locked);
        if (calls.startupError case final error?) {
          return _Titled(
            label: 'Error',
            child: Scaffold(
              body: Centered(child: Text('Sotto could not start: $error')),
            ),
          );
        }
        if (call.active) {
          return _Titled(
            label: callTitleLabel(calls),
            child: Scaffold(
              body: SafeArea(child: CallScreen(controller: calls)),
            ),
          );
        }
        if (_app.lock.locked) {
          return _Titled(
            label: 'Locked',
            child: LockScreen(lock: _app.lock),
          );
        }
        return _Titled(
          label: callTitleLabel(calls),
          child: HomeShell(app: _app, calls: calls),
        );
      },
    );
  }
}

class _Titled extends StatelessWidget {
  const _Titled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Title(
    title: 'Sotto · $label',
    color: Theme.of(context).colorScheme.primary,
    child: child,
  );
}

class _VaultProblem extends StatelessWidget {
  const _VaultProblem({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Centered(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "Sotto can't open its stored data",
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              'Reason: ${app.error}. This happens if the system keystore was '
              'reset or the data was copied from another device. Your '
              'identity is kept; contacts, links, history and settings on '
              'this device can only be recovered from a backup.',
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: app.resetStorage,
              child: const Text('Start with empty storage'),
            ),
          ],
        ),
      ),
    ),
  );
}
