import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';

Map<String, String> _messages(String locale) {
  final file = File('lib/core/l10n/arb/app_$locale.arb');
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final entry in json.entries)
      if (!entry.key.startsWith('@')) entry.key: entry.value as String,
  };
}

void main() {
  test('every language has the same keys as English, none empty', () {
    final english = _messages('en').keys.toSet();
    for (final locale in ['bn', 'ar']) {
      final messages = _messages(locale);
      expect(
        messages.keys.toSet(),
        english,
        reason: 'app_$locale.arb must match app_en.arb key for key',
      );
      for (final entry in messages.entries) {
        expect(
          entry.value.trim(),
          isNotEmpty,
          reason: '${entry.key} is empty in $locale',
        );
      }
    }
  });

  test('a saved code picks its language; anything else follows the device', () {
    expect(AppLanguage.fromCode('bn'), AppLanguage.bangla);
    expect(AppLanguage.fromCode('ar'), AppLanguage.arabic);
    expect(AppLanguage.fromCode('en'), AppLanguage.english);
    expect(AppLanguage.fromCode('fr'), AppLanguage.system);
    expect(AppLanguage.fromCode(null), AppLanguage.system);
    expect(AppLanguage.system.locale, isNull);
  });

  for (final (locale, expectedDirection) in [
    (const Locale('ar'), TextDirection.rtl),
    (const Locale('bn'), TextDirection.ltr),
    (const Locale('en'), TextDirection.ltr),
  ]) {
    testWidgets(
      '${locale.languageCode} is laid out ${expectedDirection.name}',
      (tester) async {
        late TextDirection direction;
        late String homeLabel;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppLanguage.supported,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Builder(
              builder: (context) {
                direction = Directionality.of(context);
                homeLabel = AppLocalizations.of(context).navHome;
                return const SizedBox();
              },
            ),
          ),
        );
        expect(direction, expectedDirection);
        expect(homeLabel, _messages(locale.languageCode)['navHome']);
      },
    );
  }
}
