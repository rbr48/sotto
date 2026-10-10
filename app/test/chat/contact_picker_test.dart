import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/ui/contact_picker.dart';
import 'package:sotto/contacts/contact_book.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';
import 'package:sotto/core/theme.dart';
import 'package:sotto/crypto/identity.dart';

Contact _contact(
  String name, {
  int key = 1,
  String organisation = '',
  bool verified = false,
}) => Contact(
  identity: PublicIdentity(
    signKey: Uint8List.fromList(List.filled(32, key)),
    boxKey: Uint8List(32),
  ),
  name: name,
  organisation: organisation,
  verified: verified,
  addedAt: DateTime(2024),
);

void main() {
  final bob = _contact('Bob', key: 1, organisation: 'Clinic');
  final carol = _contact('Carol', key: 2, verified: true);

  /// Pumps a button that opens the picker over [contacts]; each result (a
  /// contact, or null when dismissed) is appended to [results].
  Future<void> openPicker(
    WidgetTester tester,
    List<Contact> contacts,
    List<Contact?> results,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SottoTheme.light(),
        locale: AppLanguage.english.locale,
        supportedLocales: AppLanguage.supported,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              results.add(
                await pickContact(
                  context,
                  title: 'Choose someone',
                  contacts: contacts,
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the title, each name and organisation', (tester) async {
    final results = <Contact?>[];
    await openPicker(tester, [bob, carol], results);

    expect(find.text('Choose someone'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Clinic'), findsOneWidget);
    expect(find.text('Carol'), findsOneWidget);
    expect(results, isEmpty);
  });

  testWidgets('tapping a contact returns that contact', (tester) async {
    final results = <Contact?>[];
    await openPicker(tester, [bob, carol], results);

    await tester.tap(find.text('Carol'));
    await tester.pumpAndSettle();

    expect(results, hasLength(1));
    expect(results.single, same(carol));
  });

  testWidgets('dismissing the sheet returns null', (tester) async {
    final results = <Contact?>[];
    await openPicker(tester, [bob, carol], results);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(results, [null]);
  });
}
