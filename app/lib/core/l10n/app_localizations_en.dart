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
  String get navChats => 'Chats';

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
  String chatStatusNotSentNoAnswer(String name) {
    return 'Not sent: $name did not answer.';
  }

  @override
  String get chatEmptyHint =>
      'No messages yet. Messages are end-to-end encrypted and reach them even when their app is in the background.';

  @override
  String get chatDirectNote =>
      'Messages are end-to-end encrypted. They go directly between your devices, or sealed through the relay, which holds them for at most a minute and cannot read them.';

  @override
  String get chatRelayNote =>
      'Hide my IP is on, so messages go through the Sotto server instead of directly between your devices.';

  @override
  String get chatEmptyHintRelay =>
      'No messages yet. Hide my IP is on, so messages go through the Sotto server.';

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

  @override
  String get chatCopy => 'Copy text';

  @override
  String get chatCopied => 'Copied to clipboard';

  @override
  String get chatDeleteMessage => 'Delete message';

  @override
  String get chatDeleteMessageTitle => 'Delete this message?';

  @override
  String get chatDeleteMessageBody =>
      'This message will be removed from this device. The other person keeps their copy.';

  @override
  String get chatOpenLinkTitle => 'Open external link?';

  @override
  String chatOpenLinkBody(String url) {
    return 'Do you want to open $url in your browser?';
  }

  @override
  String get chatOpenLink => 'Open';

  @override
  String get chatStatusQueued => 'Queued';

  @override
  String get chatQueue => 'Queue';

  @override
  String get chatCancelQueue => 'Cancel queue';

  @override
  String get chatCallCompanionTooltip => 'In-call chat';

  @override
  String get chatStatusRead => 'Read';

  @override
  String get chatDayToday => 'Today';

  @override
  String get chatDayYesterday => 'Yesterday';

  @override
  String get chatVerifiedTooltip => 'You confirmed this safety number';

  @override
  String chatDisappearingActive(String duration) {
    return 'Disappearing messages: $duration timer active';
  }

  @override
  String chatRetentionMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes',
      one: '$count minute',
    );
    return '$_temp0';
  }

  @override
  String chatRetentionHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours',
      one: '$count hour',
    );
    return '$_temp0';
  }

  @override
  String chatRetentionDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '$count day',
    );
    return '$_temp0';
  }

  @override
  String get chatFileOpenFailed => 'Could not open file';

  @override
  String get chatFileSaveFailed => 'Could not save file';

  @override
  String chatBubbleSemanticsOwn(String time, String status, String text) {
    return 'You, $time, $status: $text';
  }

  @override
  String chatBubbleSemanticsOther(String name, String time, String text) {
    return '$name, $time: $text';
  }

  @override
  String get chatVoiceMessage => 'Voice message';

  @override
  String get chatStatusReceiving => 'Receiving';

  @override
  String chatTyping(String name) {
    return '$name is typing…';
  }

  @override
  String get privacySendTypingTitle => 'Send typing indicators';

  @override
  String get privacySendTypingDesc =>
      'Let contacts see when you are writing a message in real-time.';

  @override
  String get privacySendReadReceiptsTitle => 'Send read receipts';

  @override
  String get privacySendReadReceiptsDesc =>
      'Let contacts see when you have read their messages.';

  @override
  String get chatDisappearingTitle => 'Disappearing messages';

  @override
  String get chatDisappearingDesc =>
      'Automatically erase messages in this chat after the chosen duration.';

  @override
  String get chatDisappearingOff => 'Off';

  @override
  String get chatDisappearing24h => '24 hours';

  @override
  String get chatDisappearing7d => '7 days';

  @override
  String get chatDisappearing30d => '30 days';

  @override
  String get chatSearch => 'Search';

  @override
  String get chatSearchHint => 'Search in conversation';

  @override
  String get chatSearchNoMatches => 'No matching messages found';

  @override
  String get chatAttachFile => 'Attach file';

  @override
  String chatFileOffer(String name) {
    return 'File offered: $name';
  }

  @override
  String get chatFileAccept => 'Accept';

  @override
  String get chatFileDecline => 'Decline';

  @override
  String chatFileDownloading(int percent) {
    return 'Receiving $percent%';
  }

  @override
  String chatFileUploading(int percent) {
    return 'Sending $percent%';
  }

  @override
  String get chatFileReceived => 'Received file';

  @override
  String get chatFileUnavailable => 'This file is no longer on this device.';

  @override
  String get chatFileUnreadable => 'This file could not be opened.';

  @override
  String get chatFileSent => 'Sent file';

  @override
  String get chatFileOpen => 'Open';

  @override
  String get chatFileSaveAs => 'Save to…';

  @override
  String get chatFileDeclined => 'Transfer declined';

  @override
  String get chatFileCancelled => 'Transfer cancelled';

  @override
  String get chatFileFailed => 'Transfer failed';

  @override
  String get chatFileTooLarge => 'File exceeds maximum size limit (100 MB)';

  @override
  String get chatFileBlocked => 'Executables and script files cannot be sent';

  @override
  String get chatImageUnreadable =>
      'This image could not be read, so it was not sent.';

  @override
  String get chatImageUnsupported =>
      'This image type cannot be sent. Save it as a JPEG or PNG and try again.';

  @override
  String chatVoiceRecording(String time) {
    return 'Recording $time';
  }

  @override
  String get chatVoiceCancel => 'Cancel recording';

  @override
  String get chatVoiceSend => 'Send voice message';

  @override
  String get chatVoiceTooLong =>
      'Recording stopped at the 5-minute limit. Send it or cancel.';

  @override
  String get chatVoicePermission =>
      'Sotto needs permission to use the microphone. Allow it in your device settings, then try again.';

  @override
  String get chatVoiceMicPrivacy =>
      'No sound came from the microphone. Check microphone privacy settings in Windows, then try again. Nothing was sent.';

  @override
  String get chatVoiceUnavailable => 'Voice message unavailable';

  @override
  String get chatVoiceNeedsParecord =>
      'Voice messages on Linux need the pulseaudio-utils package, which provides parecord. Install it, then try again.';

  @override
  String get chatVoiceInCall =>
      'Voice messages are not available during a call.';

  @override
  String get chatVoicePlay => 'Play voice message';

  @override
  String get chatVoicePause => 'Pause voice message';
}
