import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/message_info_sheet.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';

final _sent = DateTime(2026, 10, 9, 14, 5);

ChatMessage _mine({int? deliveredAt, int? readAt}) => ChatMessage(
  id: ChatFrames.newId(),
  contactId: 'bob',
  outgoing: true,
  ts: _sent.millisecondsSinceEpoch,
  text: 'Salaam',
  state: readAt != null
      ? ChatState.read
      : deliveredAt != null
      ? ChatState.delivered
      : ChatState.sending,
  deliveredAt: deliveredAt,
  readAt: readAt,
);

Future<void> _pumpSheet(WidgetTester tester, ChatMessage message) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: AppLanguage.english.locale,
      supportedLocales: AppLanguage.supported,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: MessageInfoSheet(message: message)),
    ),
  );
}

void main() {
  group('the info sheet shows only the times this device knows', () {
    testWidgets('a message not yet delivered shows only when it was sent', (
      tester,
    ) async {
      await _pumpSheet(tester, _mine());

      expect(find.text('Message info'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Oct 9, 2026, 2:05 PM'), findsOneWidget);
      expect(find.text('Delivered'), findsNothing);
      expect(find.text('Read'), findsNothing);
    });

    testWidgets('a delivered message adds the delivered time, not a read one', (
      tester,
    ) async {
      final delivered = _sent.add(const Duration(seconds: 3));
      await _pumpSheet(
        tester,
        _mine(deliveredAt: delivered.millisecondsSinceEpoch),
      );

      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Delivered'), findsOneWidget);
      expect(find.text('Oct 9, 2026, 2:05 PM'), findsNWidgets(2));
      expect(find.text('Read'), findsNothing);
    });

    testWidgets('a read message shows all three times it has', (tester) async {
      final delivered = _sent.add(const Duration(seconds: 3));
      final read = _sent.add(const Duration(minutes: 40, seconds: 9));
      await _pumpSheet(
        tester,
        _mine(
          deliveredAt: delivered.millisecondsSinceEpoch,
          readAt: read.millisecondsSinceEpoch,
        ),
      );

      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Delivered'), findsOneWidget);
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('Oct 9, 2026, 2:45 PM'), findsOneWidget);
    });
  });
}
