// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get appName => 'Sotto';

  @override
  String get languageSetting => 'اللغة';

  @override
  String get languageSystem => 'لغة الجهاز';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageBangla => 'বাংলা';

  @override
  String get languageArabic => 'العربية';

  @override
  String get languageHelp =>
      'تغيّر لغة التطبيق. لا تتأثر جهات الاتصال والمكالمات.';

  @override
  String get navHome => 'الرئيسية';

  @override
  String get navContacts => 'جهات الاتصال';

  @override
  String get navHistory => 'السجل';

  @override
  String get navSettings => 'الإعدادات';
}
