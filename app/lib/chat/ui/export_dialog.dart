import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:sodium/sodium_sumo.dart';

import '../../core/l10n/app_localizations.dart';
import '../../storage/backup.dart';
import '../chat_export.dart';
import '../chat_store.dart';

/// Where an export's text goes, in order. [write] adds text, and [flush]
/// completes once the text written so far has reached the file.
abstract interface class ExportSink {
  void write(String text);
  Future<void> flush();
}

/// Saves an export as [fileName], writing it through [write], and returns where
/// it went, or null when the person cancels the choice of place. [mimeType] is
/// the file's type.
typedef ChatExportSave = Future<String?> Function(
  String fileName,
  String mimeType,
  Future<void> Function(ExportSink file) write,
);

/// Opens the export dialog for one chat. Returns the path the file was saved
/// to, or null when nothing was written.
Future<String?> showExportChatDialog(
  BuildContext context, {
  required SodiumSumo sodium,
  required List<ChatMessage> messages,
  required String contactName,
  required DateTime exportedAt,
  ChatExportSave? save,
  @visibleForTesting int opsLimit = ChatExport.defaultOpsLimit,
  @visibleForTesting int memLimit = ChatExport.defaultMemLimit,
}) => showDialog<String>(
  context: context,
  builder: (_) => _ExportChatDialog(
    sodium: sodium,
    messages: messages,
    contactName: contactName,
    exportedAt: exportedAt,
    save: save ?? saveChatExport,
    opsLimit: opsLimit,
    memLimit: memLimit,
  ),
);

/// Saves an export the way backups are saved: the person picks the place, or
/// on Android a folder. Nothing is written until a place is chosen. The place
/// is chosen by name, so the type is not needed to write the file.
Future<String?> saveChatExport(
  String fileName,
  String mimeType,
  Future<void> Function(ExportSink file) write,
) async {
  String? path;
  try {
    path = (await getSaveLocation(suggestedName: fileName))?.path;
  } on UnimplementedError {
    // Android: choose a folder instead.
    final folder = await getDirectoryPath();
    if (folder != null) path = '$folder/$fileName';
  }
  if (path == null) return null;
  await writeExportFile(path, write);
  return path;
}

/// Writes an export to [path] by way of a temporary file beside it. The
/// temporary file is renamed onto [path] only once every piece is written, so
/// a failed write leaves [path] as it was and no partial file behind.
Future<void> writeExportFile(
  String path,
  Future<void> Function(ExportSink file) write,
) async {
  final temp = File('$path.part');
  final io = temp.openWrite();
  try {
    await write(_FileExportSink(io));
    await io.close();
    await temp.rename(path);
  } catch (_) {
    await io.close().catchError((Object _) {});
    await temp.delete().catchError((Object _) => temp);
    rethrow;
  }
}

final class _FileExportSink implements ExportSink {
  _FileExportSink(this._io);

  final IOSink _io;

  @override
  void write(String text) => _io.write(text);

  @override
  Future<void> flush() => _io.flush();
}

/// Writes [pieces] to [file], in order. Waits for the file every
/// [ChatExport.segmentBytes] characters, so the next piece is made only once
/// the text before it is on disk.
Future<void> _writeInPieces(ExportSink file, Iterable<String> pieces) async {
  var unflushed = 0;
  for (final piece in pieces) {
    file.write(piece);
    unflushed += piece.length;
    if (unflushed >= ChatExport.segmentBytes) {
      unflushed = 0;
      await file.flush();
    }
  }
}

enum _Format { encrypted, plain }

class _ExportChatDialog extends StatefulWidget {
  const _ExportChatDialog({
    required this.sodium,
    required this.messages,
    required this.contactName,
    required this.exportedAt,
    required this.save,
    required this.opsLimit,
    required this.memLimit,
  });

  final SodiumSumo sodium;
  final List<ChatMessage> messages;
  final String contactName;
  final DateTime exportedAt;
  final ChatExportSave save;
  final int opsLimit;
  final int memLimit;

  @override
  State<_ExportChatDialog> createState() => _ExportChatDialogState();
}

class _ExportChatDialogState extends State<_ExportChatDialog> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();

  /// Encrypted is the default: plain text is offered second, after a warning.
  _Format _format = _Format.encrypted;
  bool _plainConfirmed = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !_busy && (_format == _Format.encrypted || _plainConfirmed);

  /// What is wrong with the passphrase, or null when it can be used. The
  /// rule is the one backups use.
  String? _passphraseProblem(AppLocalizations l10n) {
    final secret = _passphrase.text.trim();
    if (secret.length < Backup.minPassphraseLength) {
      return l10n.chatExportPassphraseShort(Backup.minPassphraseLength);
    }
    if (secret != _confirm.text.trim()) {
      return l10n.chatExportPassphraseMismatch;
    }
    return null;
  }

  Future<void> _save(AppLocalizations l10n) async {
    final encrypted = _format == _Format.encrypted;
    if (encrypted) {
      final problem = _passphraseProblem(l10n);
      if (problem != null) {
        setState(() => _error = problem);
        return;
      }
    } else if (!_plainConfirmed) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Let the progress bar paint before the key is derived.
    await Future<void>.delayed(const Duration(milliseconds: 16));
    try {
      final path = await widget.save(
        _fileName(encrypted),
        encrypted ? 'application/json' : 'text/plain',
        (file) => encrypted ? _writeEncrypted(file) : _writePlain(file, l10n),
      );
      if (mounted && path != null) Navigator.of(context).pop(path);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.chatFileSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _writeEncrypted(ExportSink file) async {
    final export = ChatExport.begin(
      widget.sodium,
      passphrase: _passphrase.text,
      contactName: widget.contactName,
      exportedAt: widget.exportedAt,
      messages: widget.messages,
      opsLimit: widget.opsLimit,
      memLimit: widget.memLimit,
    );
    try {
      await _writeInPieces(file, export.pieces);
    } finally {
      export.dispose();
    }
  }

  Future<void> _writePlain(ExportSink file, AppLocalizations l10n) =>
      _writeInPieces(
        file,
        ChatExport.plainPieces(
          contactName: widget.contactName,
          exportedAt: widget.exportedAt,
          messages: widget.messages,
          labels: ChatExportLabels(
            you: l10n.chatYou,
            exported: l10n.chatExportedLabel,
            file: l10n.chatExportFileLabel,
            bytes: l10n.chatExportBytesLabel,
            deleted: l10n.chatMessageDeleted,
            replyTo: l10n.chatExportReplyLabel,
            reactions: l10n.chatExportReactionsLabel,
            edited: l10n.chatEdited,
            forwarded: l10n.chatForwarded,
            delivered: l10n.chatStatusDelivered,
            read: l10n.chatStatusRead,
          ),
        ),
      );

  String _fileName(bool encrypted) {
    final day = widget.exportedAt.toIso8601String().substring(0, 10);
    return 'sotto-chat-$day.${encrypted ? 'sottochat' : 'txt'}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = Theme.of(context).colorScheme.error;
    final encrypted = _format == _Format.encrypted;
    return AlertDialog(
      title: Text(l10n.chatExportChat),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.chatExportBody),
              RadioGroup<_Format>(
                groupValue: _format,
                onChanged: (format) {
                  if (_busy || format == null) return;
                  setState(() {
                    _format = format;
                    _error = null;
                  });
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<_Format>(
                      value: _Format.encrypted,
                      title: Text(l10n.chatExportEncrypted),
                    ),
                    RadioListTile<_Format>(
                      value: _Format.plain,
                      title: Text(l10n.chatExportPlain),
                    ),
                  ],
                ),
              ),
              if (encrypted) ...[
                TextField(
                  controller: _passphrase,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.chatExportPassphrase(
                      Backup.minPassphraseLength,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirm,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.chatExportConfirmPassphrase,
                  ),
                ),
              ] else ...[
                Text(
                  l10n.chatExportPlainWarning,
                  style: TextStyle(color: error),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _plainConfirmed,
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => _plainConfirmed = value ?? false),
                  title: Text(l10n.chatExportPlainConfirm),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (_error case final message?) ...[
                const SizedBox(height: 8),
                Text(message, style: TextStyle(color: error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.chatCancel),
        ),
        FilledButton(
          onPressed: _canSave ? () => _save(l10n) : null,
          child: Text(l10n.chatExportSave),
        ),
      ],
    );
  }
}
