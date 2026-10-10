import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/export_dialog.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

const _passphrase = 'correct horse battery';
// Cheap cost keeps these tests fast; the export tests cover the defaults.
const _ops = 1;
const _mem = 8 << 20;
final _exportedAt = DateTime(2026, 10, 10, 12);

ChatMessage _message(String text, {required bool outgoing}) => ChatMessage(
  id: ChatFrames.newId(),
  contactId: 'bob',
  outgoing: outgoing,
  ts: _exportedAt.millisecondsSinceEpoch - 3600000,
  text: text,
  state: ChatState.delivered,
);

/// Records what the dialog asks to save. [answer] is where it says it went;
/// null stands for a cancelled choice of place. [gate], when set, holds the
/// save until it completes, so a test can see the dialog while it is busy.
class _Saves {
  final files =
      <({String name, String mime, String text, int pieces, int flushes})>[];
  String? answer = '/saved/place';
  bool fail = false;
  Completer<void>? gate;

  Future<String?> call(
    String name,
    String mime,
    Future<void> Function(ExportSink file) write,
  ) async {
    await gate?.future;
    final recording = _Recording();
    await write(recording);
    files.add((
      name: name,
      mime: mime,
      text: recording.text.toString(),
      pieces: recording.pieces,
      flushes: recording.flushes,
    ));
    if (fail) throw StateError('disk full');
    return answer;
  }
}

/// Keeps the text the dialog writes, and counts the pieces and the waits for
/// the file to flush.
class _Recording implements ExportSink {
  final text = StringBuffer();
  int pieces = 0;
  int flushes = 0;

  @override
  void write(String piece) {
    pieces++;
    text.write(piece);
  }

  @override
  Future<void> flush() async {
    flushes++;
  }
}

Finder _saveButton() => find.widgetWithText(FilledButton, 'Save export');

/// Presses Save, then lets the dialog's short delay and the save run.
Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(_saveButton());
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

Future<void> _open(
  WidgetTester tester, {
  required SodiumSumo sodium,
  required _Saves saves,
  required List<ChatMessage> messages,
  required void Function(String? result) onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: AppLanguage.english.locale,
      supportedLocales: AppLanguage.supported,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            onResult(
              await showExportChatDialog(
                context,
                sodium: sodium,
                opsLimit: _ops,
                memLimit: _mem,
                messages: messages,
                contactName: 'Bob',
                exportedAt: _exportedAt,
                save: saves.call,
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  late SodiumSumo sodium;
  setUpAll(
    () async => sodium = SottoCrypto.passwordHashing(await SottoCrypto.init())!,
  );

  final messages = [
    _message('Hello', outgoing: true),
    _message('Got it', outgoing: false),
  ];

  testWidgets('encrypted is preselected: passphrase fields, no warning', (
    tester,
  ) async {
    final saves = _Saves();
    await _open(
      tester,
      sodium: sodium,
      saves: saves,
      messages: messages,
      onResult: (_) {},
    );

    expect(find.text('Passphrase (at least 12 characters)'), findsOneWidget);
    expect(find.text('Confirm passphrase'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.textContaining('Anyone who has this file'), findsNothing);
  });

  testWidgets('a passphrase shorter than the minimum is refused', (
    tester,
  ) async {
    final saves = _Saves();
    await _open(
      tester,
      sodium: sodium,
      saves: saves,
      messages: messages,
      onResult: (_) {},
    );

    await tester.enterText(find.byType(TextField).at(0), 'too short');
    await tester.enterText(find.byType(TextField).at(1), 'too short');
    await tester.tap(_saveButton());
    await tester.pumpAndSettle();

    expect(
      find.text('Use a passphrase of at least 12 characters.'),
      findsOneWidget,
    );
    expect(saves.files, isEmpty);
    expect(find.text('Export chat'), findsOneWidget);
  });

  testWidgets('the two passphrases must match', (tester) async {
    final saves = _Saves();
    await _open(
      tester,
      sodium: sodium,
      saves: saves,
      messages: messages,
      onResult: (_) {},
    );

    await tester.enterText(find.byType(TextField).at(0), _passphrase);
    await tester.enterText(find.byType(TextField).at(1), '$_passphrase!');
    await tester.tap(_saveButton());
    await tester.pumpAndSettle();

    expect(find.text('The passphrases do not match.'), findsOneWidget);
    expect(saves.files, isEmpty);
  });

  testWidgets(
    'an encrypted export is saved as a sealed file, with no message text in it',
    (tester) async {
      final saves = _Saves();
      String? result;
      await _open(
        tester,
        sodium: sodium,
        saves: saves,
        messages: messages,
        onResult: (value) => result = value,
      );

      await tester.enterText(find.byType(TextField).at(0), _passphrase);
      await tester.enterText(find.byType(TextField).at(1), _passphrase);
      await _tapSave(tester);

      final file = saves.files.single;
      expect(file.mime, 'application/json');
      expect(
        file.name,
        matches(RegExp(r'^sotto-chat-\d{4}-\d{2}-\d{2}\.sottochat$')),
      );
      expect(file.text, startsWith('{"sotto":"chat-export","v":1,'));
      expect(file.text, isNot(contains('Hello')));
      expect(file.text, isNot(contains('Got it')));
      expect(result, '/saved/place');

      // The round trip (the passphrase opens the file, a wrong one does not)
      // is in chat_export_test.dart. Opening the file here would stall the
      // test at teardown, under the widget test's fake clock.
    },
  );

  testWidgets('a long export reaches the file in pieces, flushed as it goes', (
    tester,
  ) async {
    final saves = _Saves();
    final long = [
      for (var i = 0; i < 1200; i++)
        _message('message $i ${'x' * 150}', outgoing: i.isEven),
    ];
    await _open(
      tester,
      sodium: sodium,
      saves: saves,
      messages: long,
      onResult: (_) {},
    );

    await tester.enterText(find.byType(TextField).at(0), _passphrase);
    await tester.enterText(find.byType(TextField).at(1), _passphrase);
    await _tapSave(tester);

    final file = saves.files.single;
    expect(file.pieces, greaterThan(3), reason: 'header, segments, end');
    expect(
      file.flushes,
      greaterThan(1),
      reason: 'waits for the file as it goes',
    );
    expect(file.text, startsWith('{"sotto":"chat-export","v":1,'));
    expect(file.text, endsWith(']}'));
  });

  testWidgets('a progress bar shows while the export is made', (tester) async {
    final saves = _Saves()..gate = Completer<void>();
    String? result;
    await _open(
      tester,
      sodium: sodium,
      saves: saves,
      messages: messages,
      onResult: (value) => result = value,
    );

    await tester.enterText(find.byType(TextField).at(0), _passphrase);
    await tester.enterText(find.byType(TextField).at(1), _passphrase);
    await tester.tap(_saveButton());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester.widget<FilledButton>(_saveButton()).onPressed,
      isNull,
      reason: 'no second save while the first is being made',
    );

    saves.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(result, '/saved/place');
  });

  testWidgets('plain text is blocked until the warning is confirmed', (
    tester,
  ) async {
    final saves = _Saves();
    String? result;
    await _open(
      tester,
      sodium: sodium,
      saves: saves,
      messages: messages,
      onResult: (value) => result = value,
    );

    await tester.tap(find.text('Plain text'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Anyone who has this file'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(_saveButton()).onPressed,
      isNull,
      reason: 'Save stays off until the warning is confirmed',
    );
    expect(saves.files, isEmpty);

    await tester.tap(
      find.text('I understand that anyone with this file can read it.'),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(_saveButton()).onPressed, isNotNull);
    await _tapSave(tester);

    final file = saves.files.single;
    expect(file.mime, 'text/plain');
    expect(file.name, endsWith('.txt'));
    expect(file.text, contains('Hello'));
    expect(file.text, contains('Got it'));
    expect(file.text, contains('Bob'));
    expect(file.text, isNot(contains('chat-export')));
    expect(result, '/saved/place');
  });

  testWidgets('cancelling writes nothing', (tester) async {
    final saves = _Saves();
    String? result = 'not set';
    await _open(
      tester,
      sodium: sodium,
      saves: saves,
      messages: messages,
      onResult: (value) => result = value,
    );

    await tester.enterText(find.byType(TextField).at(0), _passphrase);
    await tester.enterText(find.byType(TextField).at(1), _passphrase);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(saves.files, isEmpty);
    expect(result, isNull);
    expect(find.text('Export chat'), findsNothing);
  });

  testWidgets('a cancelled choice of place keeps the dialog open', (
    tester,
  ) async {
    final saves = _Saves()..answer = null;
    String? result = 'not set';
    await _open(
      tester,
      sodium: sodium,
      saves: saves,
      messages: messages,
      onResult: (value) => result = value,
    );

    await tester.tap(find.text('Plain text'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('I understand that anyone with this file can read it.'),
    );
    await tester.pumpAndSettle();
    await _tapSave(tester);

    expect(result, 'not set');
    expect(find.text('Export chat'), findsOneWidget);
  });

  testWidgets('a save that fails says so and keeps the dialog open', (
    tester,
  ) async {
    final saves = _Saves()..fail = true;
    await _open(
      tester,
      sodium: sodium,
      saves: saves,
      messages: messages,
      onResult: (_) {},
    );

    await tester.tap(find.text('Plain text'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('I understand that anyone with this file can read it.'),
    );
    await tester.pumpAndSettle();
    await _tapSave(tester);

    expect(find.text('Could not save file'), findsOneWidget);
    expect(find.text('Export chat'), findsOneWidget);
  });
}
