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

  @override
  String get chatMessage => 'رسالة';

  @override
  String get chatWriteHint => 'اكتب رسالة';

  @override
  String get chatSend => 'إرسال';

  @override
  String get chatRetry => 'إعادة المحاولة';

  @override
  String get chatStatusSending => 'جارٍ الإرسال';

  @override
  String get chatStatusDelivered => 'تم التسليم';

  @override
  String get chatStatusNotSent => 'لم تُرسل';

  @override
  String chatStatusNotSentOffline(String name) {
    return 'لم تُرسل: $name غير متصل';
  }

  @override
  String get chatEmptyHint =>
      'لا توجد رسائل بعد. تُرسل الرسائل مباشرة إليهم عندما تكونان متصلين معاً.';

  @override
  String get chatDirectNote =>
      'تُرسل الرسائل مباشرة بين جهازيكما عندما تكونان متصلين. لا يُحفظ شيء على أي خادم.';

  @override
  String get chatDeleteMenu => 'حذف المحادثة';

  @override
  String get chatDeleteTitle => 'حذف هذه المحادثة؟';

  @override
  String get chatDeleteBody =>
      'ستُحذف الرسائل من هذا الجهاز. وتبقى نسخة لدى الطرف الآخر.';

  @override
  String get chatCancel => 'إلغاء';

  @override
  String get chatDelete => 'حذف';

  @override
  String get chatFailConnection =>
      'تعذر إنشاء الاتصال. لم تُرسل رسالتك؛ يمكنك إعادة المحاولة.';

  @override
  String get chatFailDeclined => 'لا يمكنهم استقبال الرسائل منك.';

  @override
  String get chatFailNoRelay =>
      'خيار إخفاء عنوان IP مُفعّل، لكن هذا الخادم لا يملك مُرحِّلاً للمحادثات. أوقفه، أو اطلب من المشغّل إضافة واحد.';

  @override
  String get chatEnded => 'انتهت المحادثة.';

  @override
  String get chatDismiss => 'حسناً';

  @override
  String get chatNoticeAnonymousTitle => 'رسالة جديدة';

  @override
  String chatNoticeNamedTitle(String name) {
    return 'رسالة جديدة من $name';
  }

  @override
  String get chatNoticeBody => 'افتح Sotto لقراءتها.';
}
