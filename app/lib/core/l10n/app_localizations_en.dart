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

  @override
  String get chatMessage => 'Message';

  @override
  String get chatWriteHint => 'Write a message';

  @override
  String get chatSend => 'Send';

  @override
  String get chatRetry => 'Retry';

  @override
  String get chatStatusSending => 'Sending';

  @override
  String get chatStatusDelivered => 'Delivered';

  @override
  String get chatStatusNotSent => 'Not sent';

  @override
  String chatStatusNotSentOffline(String name) {
    return 'Not sent: $name is offline';
  }

  @override
  String get chatEmptyHint =>
      'No messages yet. Messages go directly to them while you are both online.';

  @override
  String get chatDirectNote =>
      'Messages go directly between your devices while you are both online. Nothing is stored on a server.';

  @override
  String get chatDeleteMenu => 'Delete chat';

  @override
  String get chatDeleteTitle => 'Delete this chat?';

  @override
  String get chatDeleteBody =>
      'The messages are removed from this device. The other person keeps their copy.';

  @override
  String get chatCancel => 'Cancel';

  @override
  String get chatDelete => 'Delete';

  @override
  String get chatFailConnection =>
      'The connection could not be made. Your messages were not sent; you can retry.';

  @override
  String get chatFailDeclined => 'They cannot receive messages from you.';

  @override
  String get chatFailNoRelay =>
      'Hide my IP address is on, but this server has no relay for chats. Turn it off, or ask the operator to add one.';

  @override
  String get chatEnded => 'The chat has ended.';

  @override
  String get chatDismiss => 'OK';

  @override
  String get chatNoticeAnonymousTitle => 'New message';

  @override
  String chatNoticeNamedTitle(String name) {
    return 'New message from $name';
  }

  @override
  String get chatNoticeBody => 'Open Sotto to read it.';
}
