// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Sotto';

  @override
  String get languageSetting => 'Language';

  @override
  String get languageSystem => 'Device language';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageBangla => 'বাংলা';

  @override
  String get languageArabic => 'العربية';

  @override
  String get languageHelp =>
      'Changes the language of the app. Your contacts and calls are not affected.';

  @override
  String get navHome => 'Home';

  @override
  String get navContacts => 'Contacts';

  @override
  String get navHistory => 'History';

  @override
  String get navSettings => 'Settings';
}
