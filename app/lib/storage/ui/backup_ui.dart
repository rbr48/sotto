import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../backup.dart';

String describeBackupProblem(BackupProblem problem) => switch (problem) {
  BackupProblem.notABackup => 'That is not a Sotto backup, or it is damaged.',
  BackupProblem.unsupportedVersion =>
    'This backup was made by a newer version of Sotto. Update the app first.',
  BackupProblem.wrongPassphrase =>
    'Wrong passphrase, or the backup was changed.',
  BackupProblem.weakPassphrase =>
    'Use a passphrase of at least ${Backup.minPassphraseLength} characters.',
};

/// Paste or open a backup and enter its passphrase.
class RestoreBackupForm extends StatefulWidget {
  const RestoreBackupForm({super.key, required this.app, this.onRestored});

  final AppController app;
  final VoidCallback? onRestored;

  @override
  State<RestoreBackupForm> createState() => _RestoreBackupFormState();
}

class _RestoreBackupFormState extends State<RestoreBackupForm> {
  final _text = TextEditingController();
  final _passphrase = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _openFile() async {
    try {
      final file = await openFile();
      if (file == null) return;
      final text = await file.readAsString();
      setState(() => _text.text = text.trim());
    } catch (e) {
      setState(() => _error = 'Could not read that file ($e).');
    }
  }

  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 16));
    try {
      await widget.app.restoreBackup(_text.text, _passphrase.text);
      widget.onRestored?.call();
    } on BackupException catch (e) {
      setState(() => _error = describeBackupProblem(e.problem));
    } catch (e) {
      setState(() => _error = 'Restoring failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _text,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Backup (paste it, or open the file)',
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Open backup file',
            onPressed: _openFile,
            icon: const Icon(Icons.file_open_outlined),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _passphrase,
        obscureText: true,
        decoration: InputDecoration(
          labelText: 'Backup passphrase',
          errorText: _error,
          errorMaxLines: 3,
        ),
        onSubmitted: (_) => _restore(),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _busy ? null : _restore,
        icon: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.restore),
        label: const Text('Restore'),
      ),
    ],
  );
}

/// Creates a backup and lets the user save or copy it.
Future<void> showExportBackupDialog(BuildContext context, AppController app) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ExportBackupDialog(app: app),
    );

class _ExportBackupDialog extends StatefulWidget {
  const _ExportBackupDialog({required this.app});

  final AppController app;

  @override
  State<_ExportBackupDialog> createState() => _ExportBackupDialogState();
}

class _ExportBackupDialogState extends State<_ExportBackupDialog> {
  final _passphrase = TextEditingController();
  bool _includeHistory = true;
  bool _wroteItDown = false;
  bool _generated = false;
  bool _busy = false;
  String? _error;
  String? _backup;
  String? _savedTo;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  void _generate() => setState(() {
    _passphrase.text = Backup.generatePassphrase(widget.app.sodium);
    _generated = true;
  });

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 16));
    try {
      final backup = await widget.app.exportBackup(
        _passphrase.text,
        includeHistory: _includeHistory,
      );
      setState(() => _backup = backup);
    } on BackupException catch (e) {
      setState(() => _error = describeBackupProblem(e.problem));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _fileName {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return 'sotto-backup-$today.${Backup.fileExtension}';
  }

  Future<void> _save() async {
    final backup = _backup!;
    final file = XFile.fromData(
      Uint8List.fromList(utf8.encode(backup)),
      mimeType: 'application/json',
      name: _fileName,
    );
    try {
      String? path;
      try {
        path = (await getSaveLocation(suggestedName: _fileName))?.path;
      } on UnimplementedError {
        // Android: choose a folder instead.
        final folder = await getDirectoryPath();
        if (folder != null) path = '$folder/$_fileName';
      }
      if (path == null) return;
      await file.saveTo(path);
      setState(() => _savedTo = path);
    } catch (e) {
      setState(
        () => _error = 'Could not save the file ($e). Copy the backup instead.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final backup = _backup;
    return AlertDialog(
      title: const Text('Back up Sotto'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: backup == null
                ? [
                    const Text(
                      'The backup holds your identity, contacts, guest links '
                      'and settings, encrypted with a passphrase. Anyone with '
                      'the backup and the passphrase can use your identity, so '
                      'keep them apart. Without the passphrase, nobody (not '
                      'even us) can open it.',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passphrase,
                      onChanged: (_) => setState(() => _generated = false),
                      decoration: InputDecoration(
                        labelText:
                            'Passphrase (at least ${Backup.minPassphraseLength} characters)',
                        errorText: _error,
                        errorMaxLines: 3,
                        suffixIcon: IconButton(
                          tooltip: 'Generate a strong passphrase',
                          onPressed: _generate,
                          icon: const Icon(Icons.casino_outlined),
                        ),
                      ),
                    ),
                    if (_generated)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: SelectableText(
                          _passphrase.text,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 16,
                          ),
                        ),
                      ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _includeHistory,
                      onChanged: (v) =>
                          setState(() => _includeHistory = v ?? true),
                      title: const Text('Include call history and notes'),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _wroteItDown,
                      onChanged: (v) =>
                          setState(() => _wroteItDown = v ?? false),
                      title: const Text(
                        'I wrote the passphrase down somewhere safe',
                      ),
                    ),
                  ]
                : [
                    const Text(
                      'Your backup is ready. Save it somewhere other than '
                      'this device, for example a USB stick.',
                    ),
                    if (_savedTo case final path?) ...[
                      const SizedBox(height: 8),
                      Text('Saved to $path'),
                    ],
                    if (_error case final error?) ...[
                      const SizedBox(height: 8),
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
          ),
        ),
      ),
      actions: backup == null
          ? [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: _busy || !_wroteItDown ? null : _create,
                child: const Text('Create backup'),
              ),
            ]
          : [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: backup));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Backup copied')),
                  );
                },
                child: const Text('Copy'),
              ),
              if (!kIsWeb)
                TextButton(onPressed: _save, child: const Text('Save file')),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
    );
  }
}
