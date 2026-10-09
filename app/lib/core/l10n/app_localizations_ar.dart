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
  String get navChats => 'المحادثات';

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
  String chatStatusNotSentNoAnswer(String name) {
    return 'لم تُرسل: $name لم يرد.';
  }

  @override
  String get chatEmptyHint =>
      'لا توجد رسائل بعد. تُرسل الرسائل مباشرة إليهم عندما تكونان متصلين معاً.';

  @override
  String get chatDirectNote =>
      'تُرسل الرسائل مباشرة بين جهازيكما عندما تكونان متصلين.';

  @override
  String get chatRelayNote =>
      'خيار إخفاء عنوان IP مُفعّل، لذلك تمرّ الرسائل عبر خادم Sotto بدلاً من أن تُرسل مباشرة بين جهازيكما.';

  @override
  String get chatEmptyHintRelay =>
      'لا توجد رسائل بعد. خيار إخفاء عنوان IP مُفعّل، لذلك تمرّ الرسائل عبر خادم Sotto.';

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

  @override
  String get chatCopy => 'نسخ النص';

  @override
  String get chatCopied => 'تم النسخ إلى الحافظة';

  @override
  String get chatDeleteMessage => 'حذف الرسالة';

  @override
  String get chatDeleteMessageTitle => 'حذف هذه الرسالة؟';

  @override
  String get chatDeleteMessageBody =>
      'ستتم إزالة هذه الرسالة من هذا الجهاز. يحتفظ الطرف الآخر بنسخته.';

  @override
  String get chatOpenLinkTitle => 'فتح رابط خارجي؟';

  @override
  String chatOpenLinkBody(String url) {
    return 'هل تريد فتح $url في متصفحك؟';
  }

  @override
  String get chatOpenLink => 'فتح';

  @override
  String get chatStatusQueued => 'قيد الانتظار';

  @override
  String get chatQueue => 'وضع في الانتظار';

  @override
  String get chatCancelQueue => 'إلغاء الانتظار';

  @override
  String get chatCallCompanionTooltip => 'محادثة أثناء المكالمة';

  @override
  String get chatStatusRead => 'تمت القراءة';

  @override
  String get chatDayToday => 'اليوم';

  @override
  String get chatDayYesterday => 'أمس';

  @override
  String get chatVerifiedTooltip => 'أكّدتَ رقم الأمان هذا';

  @override
  String chatDisappearingActive(String duration) {
    return 'الرسائل ذاتية الاختفاء: المؤقت $duration مفعّل';
  }

  @override
  String chatRetentionMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count دقيقة',
      many: '$count دقيقة',
      few: '$count دقائق',
      two: 'دقيقتان',
      one: 'دقيقة واحدة',
      zero: '$count دقيقة',
    );
    return '$_temp0';
  }

  @override
  String chatRetentionHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ساعة',
      many: '$count ساعة',
      few: '$count ساعات',
      two: 'ساعتان',
      one: 'ساعة واحدة',
      zero: '$count ساعة',
    );
    return '$_temp0';
  }

  @override
  String chatRetentionDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count يوم',
      many: '$count يومًا',
      few: '$count أيام',
      two: 'يومان',
      one: 'يوم واحد',
      zero: '$count يوم',
    );
    return '$_temp0';
  }

  @override
  String get chatFileOpenFailed => 'تعذّر فتح الملف';

  @override
  String get chatFileSaveFailed => 'تعذّر حفظ الملف';

  @override
  String chatBubbleSemanticsOwn(String time, String status, String text) {
    return 'أنت، $time، $status: $text';
  }

  @override
  String chatBubbleSemanticsOther(String name, String time, String text) {
    return '$name، $time: $text';
  }

  @override
  String get chatVoiceMessage => 'رسالة صوتية';

  @override
  String get chatStatusReceiving => 'جارٍ الاستلام';

  @override
  String chatTyping(String name) {
    return '$name يكتب الآن…';
  }

  @override
  String get privacySendTypingTitle => 'إرسال مؤشرات الكتابة';

  @override
  String get privacySendTypingDesc =>
      'السماح لجهات الاتصال بمعرفة متى تكتب رسالة في الوقت الفعلي.';

  @override
  String get privacySendReadReceiptsTitle => 'إرسال إشعارات القراءة';

  @override
  String get privacySendReadReceiptsDesc =>
      'السماح لجهات الاتصال بمعرفة متى قرأت رسائلهم.';

  @override
  String get chatDisappearingTitle => 'الرسائل ذاتية الاختفاء';

  @override
  String get chatDisappearingDesc =>
      'حذف الرسائل تلقائياً في هذه المحادثة بعد انتهاء المدة المحددة.';

  @override
  String get chatDisappearingOff => 'متوقف';

  @override
  String get chatDisappearing24h => '24 ساعة';

  @override
  String get chatDisappearing7d => '7 أيام';

  @override
  String get chatDisappearing30d => '30 يوماً';

  @override
  String get chatSearch => 'بحث';

  @override
  String get chatSearchHint => 'البحث في المحادثة';

  @override
  String get chatSearchNoMatches => 'لم يتم العثور على رسائل مطابقة';

  @override
  String get chatAttachFile => 'إرفاق ملف';

  @override
  String chatFileOffer(String name) {
    return 'ملف معروض: $name';
  }

  @override
  String get chatFileAccept => 'قبول';

  @override
  String get chatFileDecline => 'رفض';

  @override
  String chatFileDownloading(int percent) {
    return 'جارٍ الاستلام $percent%';
  }

  @override
  String chatFileUploading(int percent) {
    return 'جارٍ الإرسال $percent%';
  }

  @override
  String get chatFileReceived => 'تم استلام الملف';

  @override
  String get chatFileUnavailable => 'لم يعد هذا الملف موجودا على هذا الجهاز.';

  @override
  String get chatFileUnreadable => 'تعذر فتح هذا الملف.';

  @override
  String get chatFileSent => 'تم إرسال الملف';

  @override
  String get chatFileOpen => 'فتح';

  @override
  String get chatFileSaveAs => 'حفظ باسم…';

  @override
  String get chatFileDeclined => 'تم رفض النقل';

  @override
  String get chatFileCancelled => 'تم إلغاء النقل';

  @override
  String get chatFileFailed => 'فشل النقل';

  @override
  String get chatFileTooLarge =>
      'الملف يتجاوز الحد الأقصى للحجم (100 ميجابايت)';

  @override
  String get chatFileBlocked =>
      'لا يمكن إرسال الملفات القابلة للتنفيذ أو البرمجية';

  @override
  String get chatImageUnreadable => 'تعذّرت قراءة هذه الصورة، فلم يُرسل الملف.';

  @override
  String get chatImageUnsupported =>
      'لا يمكن إرسال نوع الصورة هذا. احفظها بصيغة JPEG أو PNG ثم حاول مرة أخرى.';

  @override
  String chatVoiceRecording(String time) {
    return 'جارٍ التسجيل $time';
  }

  @override
  String get chatVoiceCancel => 'إلغاء التسجيل';

  @override
  String get chatVoiceSend => 'إرسال الرسالة الصوتية';

  @override
  String get chatVoiceTooLong =>
      'توقف التسجيل عند الحد الأقصى وهو 5 دقائق. أرسله أو ألغِه.';

  @override
  String get chatVoicePermission =>
      'يحتاج Sotto إلى إذن لاستخدام الميكروفون. اسمح بذلك من إعدادات الجهاز ثم حاول مرة أخرى.';

  @override
  String get chatVoiceMicPrivacy =>
      'لم يصل أي صوت من الميكروفون. تحقق من إعدادات خصوصية الميكروفون في Windows ثم حاول مرة أخرى. لم يُرسل شيء.';

  @override
  String get chatVoiceUnavailable => 'الرسالة الصوتية غير متاحة';

  @override
  String get chatVoiceNeedsParecord =>
      'تحتاج الرسائل الصوتية على Linux إلى الحزمة pulseaudio-utils، وهي توفر الأمر parecord. ثبّتها ثم حاول مرة أخرى.';

  @override
  String get chatVoiceInCall => 'الرسائل الصوتية غير متاحة أثناء المكالمة.';

  @override
  String get chatVoicePlay => 'تشغيل الرسالة الصوتية';

  @override
  String get chatVoicePause => 'إيقاف الرسالة الصوتية مؤقتاً';
}
