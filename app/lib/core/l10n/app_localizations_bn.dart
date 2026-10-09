// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Bengali Bangla (`bn`).
class AppLocalizationsBn extends AppLocalizations {
  AppLocalizationsBn([String locale = 'bn']) : super(locale);

  @override
  String chatFilesTooMany(int max) {
    return 'শুধু প্রথম $maxটি ফাইল পাঠানো হয়েছে। একবারে সর্বোচ্চ $maxটি বেছে নিন।';
  }

  @override
  String chatFilesSkipped(int count, String names) {
    return '$countটি ফাইল পাঠানো হয়নি: $names';
  }

  @override
  String get appName => 'Sotto';

  @override
  String get languageSetting => 'ভাষা';

  @override
  String get languageSystem => 'ডিভাইসের ভাষা';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageBangla => 'বাংলা';

  @override
  String get languageArabic => 'العربية';

  @override
  String get languageHelp =>
      'অ্যাপের ভাষা বদলায়। আপনার পরিচিতি ও কলে কোনো প্রভাব পড়ে না।';

  @override
  String get navHome => 'হোম';

  @override
  String get navChats => 'চ্যাট';

  @override
  String get navContacts => 'পরিচিতি';

  @override
  String get navHistory => 'ইতিহাস';

  @override
  String get navSettings => 'সেটিংস';

  @override
  String get chatMessage => 'বার্তা';

  @override
  String get chatWriteHint => 'একটি বার্তা লিখুন';

  @override
  String get chatSend => 'পাঠান';

  @override
  String get chatRetry => 'আবার চেষ্টা করুন';

  @override
  String get chatStatusSending => 'পাঠানো হচ্ছে';

  @override
  String get chatStatusDelivered => 'পৌঁছেছে';

  @override
  String get chatStatusNotSent => 'পাঠানো যায়নি';

  @override
  String chatStatusNotSentNoAnswer(String name) {
    return 'পাঠানো যায়নি: $name সাড়া দেননি।';
  }

  @override
  String get chatEmptyHint =>
      'এখনো কোনো বার্তা নেই। বার্তাগুলো এন্ড-টু-এন্ড এনক্রিপ্টেড, এবং তাদের অ্যাপ ব্যাকগ্রাউন্ডে থাকলেও পৌঁছায়।';

  @override
  String get chatDirectNote =>
      'বার্তাগুলো এন্ড-টু-এন্ড এনক্রিপ্টেড। এগুলো সরাসরি আপনাদের ডিভাইসের মধ্যে যায়, অথবা সিল করা অবস্থায় রিলে দিয়ে যায়; রিলে এগুলো সর্বোচ্চ এক মিনিট রাখে এবং পড়তে পারে না।';

  @override
  String get chatRelayNote =>
      'আইপি ঠিকানা লুকানো চালু আছে, তাই বার্তা সরাসরি না গিয়ে Sotto সার্ভারের মধ্য দিয়ে যায়।';

  @override
  String get chatEmptyHintRelay =>
      'এখনও কোনো বার্তা নেই। আইপি ঠিকানা লুকানো চালু আছে, তাই বার্তা Sotto সার্ভারের মধ্য দিয়ে যায়।';

  @override
  String get chatDeleteMenu => 'চ্যাট মুছুন';

  @override
  String get chatDeleteTitle => 'এই চ্যাট মুছবেন?';

  @override
  String get chatDeleteBody =>
      'এই ডিভাইস থেকে বার্তাগুলো মুছে যাবে। অন্য ব্যক্তির কপি থেকে যাবে।';

  @override
  String get chatCancel => 'বাতিল';

  @override
  String get chatDelete => 'মুছুন';

  @override
  String get chatFailConnection =>
      'সংযোগ স্থাপন করা যায়নি। আপনার বার্তা পাঠানো হয়নি; আবার চেষ্টা করতে পারেন।';

  @override
  String get chatFailDeclined => 'তারা আপনার কাছ থেকে বার্তা নিতে পারেন না।';

  @override
  String get chatFailNoRelay =>
      'আইপি ঠিকানা লুকানো চালু আছে, কিন্তু এই সার্ভারে চ্যাটের জন্য রিলে নেই। বন্ধ করুন, অথবা সার্ভার পরিচালককে একটি যোগ করতে বলুন।';

  @override
  String get chatEnded => 'চ্যাট শেষ হয়েছে।';

  @override
  String get chatDismiss => 'ঠিক আছে';

  @override
  String get chatNoticeAnonymousTitle => 'নতুন বার্তা';

  @override
  String chatNoticeNamedTitle(String name) {
    return '$name-এর কাছ থেকে নতুন বার্তা';
  }

  @override
  String get chatNoticeBody => 'পড়তে Sotto খুলুন।';

  @override
  String get chatCopy => 'লেখা কপি করুন';

  @override
  String get chatCopied => 'ক্লিপবোর্ডে কপি করা হয়েছে';

  @override
  String get chatDeleteMessage => 'বার্তা মুছুন';

  @override
  String get chatDeleteMessageTitle => 'এই বার্তাটি মুছবেন?';

  @override
  String get chatDeleteMessageBody =>
      'বার্তাটি এই ডিভাইস থেকে মুছে ফেলা হবে। অপর পক্ষ তাদের কপি সংরক্ষণ করবে।';

  @override
  String get chatOpenLinkTitle => 'বাহ্যিক লিঙ্ক খুলবেন?';

  @override
  String chatOpenLinkBody(String url) {
    return 'আপনি কি আপনার ব্রাউজারে $url লিঙ্কটি খুলতে চান?';
  }

  @override
  String get chatOpenLink => 'খুলুন';

  @override
  String get chatStatusQueued => 'অপেক্ষারত';

  @override
  String get chatQueue => 'অপেক্ষায় রাখুন';

  @override
  String get chatCancelQueue => 'বাতিল করুন';

  @override
  String get chatCallCompanionTooltip => 'কল চলাকালীন চ্যাট';

  @override
  String get chatStatusRead => 'পড়া হয়েছে';

  @override
  String get chatDayToday => 'আজ';

  @override
  String get chatDayYesterday => 'গতকাল';

  @override
  String get chatVerifiedTooltip => 'আপনি এই নিরাপত্তা নম্বরটি নিশ্চিত করেছেন';

  @override
  String chatDisappearingActive(String duration) {
    return 'স্বয়ংক্রিয়ভাবে মুছে যাওয়া বার্তা: $duration টাইমার চালু';
  }

  @override
  String chatRetentionMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count মিনিট',
      one: '$count মিনিট',
    );
    return '$_temp0';
  }

  @override
  String chatRetentionHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ঘণ্টা',
      one: '$count ঘণ্টা',
    );
    return '$_temp0';
  }

  @override
  String chatRetentionDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count দিন',
      one: '$count দিন',
    );
    return '$_temp0';
  }

  @override
  String get chatFileOpenFailed => 'ফাইলটি খোলা যায়নি';

  @override
  String get chatFileSaveFailed => 'ফাইলটি সংরক্ষণ করা যায়নি';

  @override
  String chatBubbleSemanticsOwn(String time, String status, String text) {
    return 'আপনি, $time, $status: $text';
  }

  @override
  String chatBubbleSemanticsOther(String name, String time, String text) {
    return '$name, $time: $text';
  }

  @override
  String get chatVoiceMessage => 'ভয়েস বার্তা';

  @override
  String get chatStatusReceiving => 'আনা হচ্ছে';

  @override
  String chatTyping(String name) {
    return '$name লিখছেন…';
  }

  @override
  String get privacySendTypingTitle => 'টাইপিং নির্দেশক পাঠান';

  @override
  String get privacySendTypingDesc =>
      'আপনি কখন বার্তা লিখছেন তা পরিচিতিদের রিয়েল-টাইমে দেখতে দিন।';

  @override
  String get privacySendReadReceiptsTitle => 'পড়ার স্বীকৃতি পাঠান';

  @override
  String get privacySendReadReceiptsDesc =>
      'আপনি কখন তাদের বার্তা পড়েছেন তা পরিচিতিদের দেখতে দিন।';

  @override
  String get chatDisappearingTitle => 'স্বয়ংক্রিয় বার্তা মুছে ফেলা';

  @override
  String get chatDisappearingDesc =>
      'নির্বাচিত সময় পরে এই চ্যাটের বার্তাগুলো স্বয়ংক্রিয়ভাবে মুছে যাবে।';

  @override
  String get chatDisappearingOff => 'বন্ধ';

  @override
  String get chatDisappearing24h => '২৪ ঘন্টা';

  @override
  String get chatDisappearing7d => '৭ দিন';

  @override
  String get chatDisappearing30d => '৩০ দিন';

  @override
  String get chatSearch => 'অনুসন্ধান';

  @override
  String get chatSearchHint => 'কথোপকথনে অনুসন্ধান করুন';

  @override
  String get chatSearchNoMatches => 'কোনো বার্তা পাওয়া যায়নি';

  @override
  String get chatAttachFile => 'ফাইল সংযুক্ত করুন';

  @override
  String chatFileOffer(String name) {
    return 'ফাইল পাঠানো হয়েছে: $name';
  }

  @override
  String get chatFileAccept => 'গ্রহণ করুন';

  @override
  String get chatFileDecline => 'প্রত্যাখ্যান করুন';

  @override
  String chatFileDownloading(int percent) {
    return 'আনা হচ্ছে $percent%';
  }

  @override
  String chatFileUploading(int percent) {
    return 'পাঠানো হচ্ছে $percent%';
  }

  @override
  String get chatFileReceived => 'ফাইল পাওয়া গেছে';

  @override
  String get chatFileUnavailable => 'ফাইলটি আর এই ডিভাইসে নেই।';

  @override
  String get chatFileUnreadable => 'ফাইলটি খোলা যায়নি।';

  @override
  String get chatFileSent => 'ফাইল পাঠানো হয়েছে';

  @override
  String get chatFileOpen => 'খুলুন';

  @override
  String get chatFileSaveAs => 'সংরক্ষণ করুন…';

  @override
  String get chatFileDeclined => 'স্থানান্তর প্রত্যাখ্যাত';

  @override
  String get chatFileCancelled => 'স্থানান্তর বাতিল';

  @override
  String get chatFileFailed => 'স্থানান্তর ব্যর্থ হয়েছে';

  @override
  String get chatFileTooLarge =>
      'ফাইলের আকার সর্বোচ্চ সীমা (১০০ মেগাবাইট) অতিক্রম করেছে';

  @override
  String get chatFileBlocked =>
      'এক্সিকিউটেবল এবং স্ক্রিপ্ট ফাইল পাঠানো যাবে না';

  @override
  String get chatImageUnreadable =>
      'এই ছবিটি পড়া যায়নি, তাই ফাইলটি পাঠানো হয়নি।';

  @override
  String get chatImageUnsupported =>
      'এই ধরনের ছবি পাঠানো যাবে না। ছবিটি JPEG বা PNG হিসেবে সেভ করে আবার চেষ্টা করুন।';

  @override
  String chatVoiceRecording(String time) {
    return 'রেকর্ড হচ্ছে $time';
  }

  @override
  String get chatVoiceCancel => 'রেকর্ড বাতিল করুন';

  @override
  String get chatVoiceSend => 'ভয়েস বার্তা পাঠান';

  @override
  String get chatVoiceTooLong =>
      '৫ মিনিটের সীমায় রেকর্ড থেমেছে। পাঠান বা বাতিল করুন।';

  @override
  String get chatVoicePermission =>
      'ভয়েস বার্তার জন্য Sotto-কে মাইক্রোফোন ব্যবহারের অনুমতি দিতে হবে। ডিভাইসের সেটিংসে অনুমতি দিয়ে আবার চেষ্টা করুন।';

  @override
  String get chatVoiceMicPrivacy =>
      'মাইক্রোফোন থেকে কোনো শব্দ আসেনি। Windows-এর মাইক্রোফোন গোপনীয়তা সেটিংস দেখুন, তারপর আবার চেষ্টা করুন। কিছুই পাঠানো হয়নি।';

  @override
  String get chatVoiceUnavailable => 'ভয়েস বার্তা উপলব্ধ নেই';

  @override
  String get chatVoiceNeedsParecord =>
      'Linux-এ ভয়েস বার্তার জন্য pulseaudio-utils প্যাকেজ লাগবে, যাতে parecord থাকে। সেটি ইনস্টল করে আবার চেষ্টা করুন।';

  @override
  String get chatVoiceInCall => 'কল চলাকালীন ভয়েস বার্তা পাওয়া যায় না।';

  @override
  String get chatVoicePlay => 'ভয়েস বার্তা চালান';

  @override
  String get chatVoicePause => 'ভয়েস বার্তা থামান';
}
