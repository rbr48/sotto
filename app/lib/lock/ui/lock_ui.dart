import 'dart:async';

import 'package:flutter/material.dart';

import '../../call/ui/common.dart';
import '../app_lock.dart';

/// Shown while the app is locked. Calls still ring on top of it.
class LockScreen extends StatelessWidget {
  const LockScreen({super.key, required this.lock});

  final AppLock lock;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Centered(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.lock_outline,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Sotto is locked',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Calls still ring while Sotto is locked.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            _PinEntry(lock: lock, buttonLabel: 'Unlock', onSubmit: lock.unlock),
          ],
        ),
      ),
    ),
  );
}

/// A PIN field with an action button, wrong-PIN messages and the waiting
/// time after too many attempts.
class _PinEntry extends StatefulWidget {
  const _PinEntry({
    required this.lock,
    required this.buttonLabel,
    required this.onSubmit,
    this.onDone,
  });

  final AppLock lock;
  final String buttonLabel;
  final Future<UnlockResult> Function(String pin) onSubmit;
  final VoidCallback? onDone;

  @override
  State<_PinEntry> createState() => _PinEntryState();
}

class _PinEntryState extends State<_PinEntry> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.lock.retryIn > Duration.zero || _error != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    // Let the spinner show before Argon2id runs.
    await Future<void>.delayed(const Duration(milliseconds: 16));
    final result = await widget.onSubmit(_pin.text);
    if (!mounted) return;
    _pin.clear();
    setState(() {
      _busy = false;
      _error = switch (result) {
        UnlockResult.unlocked => null,
        UnlockResult.wrongPin => 'Wrong PIN.',
        UnlockResult.tooManyAttempts => 'Too many wrong PINs.',
      };
    });
    if (result == UnlockResult.unlocked) widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final wait = widget.lock.retryIn;
    final waiting = wait > Duration.zero;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _pin,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: AppLock.maxPinLength,
          enabled: !waiting && !_busy,
          decoration: InputDecoration(
            labelText: 'PIN',
            errorText: waiting
                ? 'Too many wrong PINs. Try again in ${formatDuration(wait)}.'
                : _error,
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: waiting || _busy ? null : _submit,
          child: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.buttonLabel),
        ),
      ],
    );
  }
}

/// Asks for the PIN before a sensitive change (auto-answer, backups).
/// Without a PIN, the user must set one first. Returns whether to proceed.
Future<bool> confirmWithPin(
  BuildContext context,
  AppLock lock, {
  required String reason,
}) async {
  if (!lock.hasPin) {
    return await showSetPinDialog(
      context,
      lock,
      explanation:
          '$reason needs an app lock, so nobody else can change it on '
          'this device. Choose a PIN.',
    );
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Enter your PIN'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(reason),
            const SizedBox(height: 12),
            _PinEntry(
              lock: lock,
              buttonLabel: 'Confirm',
              onSubmit: lock.check,
              onDone: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Sets (or replaces) the PIN: entered twice. Returns whether it was set.
Future<bool> showSetPinDialog(
  BuildContext context,
  AppLock lock, {
  String? explanation,
}) async {
  final set = await showDialog<bool>(
    context: context,
    builder: (_) => _SetPinDialog(lock: lock, explanation: explanation),
  );
  return set ?? false;
}

class _SetPinDialog extends StatefulWidget {
  const _SetPinDialog({required this.lock, this.explanation});

  final AppLock lock;
  final String? explanation;

  @override
  State<_SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<_SetPinDialog> {
  final _pin = TextEditingController();
  final _again = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!AppLock.isValidPin(_pin.text)) {
      setState(
        () => _error =
            'Use ${AppLock.minPinLength} to ${AppLock.maxPinLength} digits.',
      );
      return;
    }
    if (_pin.text != _again.text) {
      setState(() => _error = 'The PINs are different.');
      return;
    }
    setState(() => _busy = true);
    await Future<void>.delayed(const Duration(milliseconds: 16));
    await widget.lock.setPin(_pin.text);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Set a PIN'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.explanation ??
                'The PIN locks Sotto when you leave it, and protects '
                    'auto-answer and backups.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: AppLock.maxPinLength,
            decoration: const InputDecoration(
              labelText: 'New PIN (at least 6 digits)',
            ),
          ),
          TextField(
            controller: _again,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: AppLock.maxPinLength,
            decoration: InputDecoration(
              labelText: 'Repeat the PIN',
              errorText: _error,
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: const Text('Save PIN'),
      ),
    ],
  );
}
