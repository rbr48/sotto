import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The language the person picked. [system] follows the device.
///
/// Only the choice is stored, in the browser or the device's preferences, so
/// it can be read before the app lock. It is not sensitive.
enum AppLanguage {
  system(null),
  english(Locale('en')),
  bangla(Locale('bn')),
  arabic(Locale('ar'));

  const AppLanguage(this.locale);

  /// Null for [system]: Flutter then uses the device's language list.
  final Locale? locale;

  static const storageKey = 'sotto.language';

  /// English first: it is the fallback when the device language is not one
  /// of these.
  static const supported = [Locale('en'), Locale('bn'), Locale('ar')];

  static AppLanguage fromCode(String? code) => switch (code) {
    'en' => english,
    'bn' => bangla,
    'ar' => arabic,
    _ => system,
  };

  String get code => locale?.languageCode ?? 'system';
}

/// The current choice. The app rebuilds when it changes.
final appLanguage = ValueNotifier<AppLanguage>(AppLanguage.system);

/// Reads the saved choice into [appLanguage]. Any failure keeps the device's
/// language: a missing preference must never stop the app starting.
Future<void> loadAppLanguage() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    appLanguage.value = AppLanguage.fromCode(
      prefs.getString(AppLanguage.storageKey),
    );
  } catch (_) {
    // Keep the device's language.
  }
}

/// Changes the language now and remembers it.
Future<void> chooseAppLanguage(AppLanguage language) async {
  appLanguage.value = language;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppLanguage.storageKey, language.code);
  } catch (_) {
    // Applied for this session only.
  }
}
