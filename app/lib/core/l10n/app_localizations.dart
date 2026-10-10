import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_bn.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('bn'),
    Locale('en'),
  ];

  /// No description provided for @chatFilesTooMany.
  ///
  /// In en, this message translates to:
  /// **'Only the first {max} files were sent. Pick up to {max} at a time.'**
  String chatFilesTooMany(int max);

  /// No description provided for @chatFilesSkipped.
  ///
  /// In en, this message translates to:
  /// **'{count} files were not sent: {names}'**
  String chatFilesSkipped(int count, String names);

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'Sotto'**
  String get appName;

  /// No description provided for @languageSetting.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageSetting;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'Device language'**
  String get languageSystem;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageBangla.
  ///
  /// In en, this message translates to:
  /// **'বাংলা'**
  String get languageBangla;

  /// No description provided for @languageArabic.
  ///
  /// In en, this message translates to:
  /// **'العربية'**
  String get languageArabic;

  /// No description provided for @languageHelp.
  ///
  /// In en, this message translates to:
  /// **'Changes the language of the app. Your contacts and calls are not affected.'**
  String get languageHelp;

  /// No description provided for @avatarChangePhoto.
  ///
  /// In en, this message translates to:
  /// **'Change photo'**
  String get avatarChangePhoto;

  /// No description provided for @avatarRemovePhoto.
  ///
  /// In en, this message translates to:
  /// **'Remove photo'**
  String get avatarRemovePhoto;

  /// No description provided for @avatarVisibilityNote.
  ///
  /// In en, this message translates to:
  /// **'People who have your contact link can see your photo.'**
  String get avatarVisibilityNote;

  /// No description provided for @avatarInputTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Choose an image under 10 MB.'**
  String get avatarInputTooLarge;

  /// No description provided for @avatarUnreadable.
  ///
  /// In en, this message translates to:
  /// **'That file could not be read as a picture. Try a JPEG or PNG.'**
  String get avatarUnreadable;

  /// No description provided for @avatarTooLarge.
  ///
  /// In en, this message translates to:
  /// **'That picture could not be made small enough to share. Try another one.'**
  String get avatarTooLarge;

  /// No description provided for @avatarFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not set the photo.'**
  String get avatarFailed;

  /// No description provided for @profileSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved. Guest links show your new name; your contact link shows your new name and photo.'**
  String get profileSaved;

  /// No description provided for @navHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// No description provided for @navChats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get navChats;

  /// No description provided for @navContacts.
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get navContacts;

  /// No description provided for @navHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get navHistory;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @chatMessage.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get chatMessage;

  /// No description provided for @chatWriteHint.
  ///
  /// In en, this message translates to:
  /// **'Write a message'**
  String get chatWriteHint;

  /// No description provided for @chatSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get chatSend;

  /// No description provided for @chatRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get chatRetry;

  /// No description provided for @chatStatusSending.
  ///
  /// In en, this message translates to:
  /// **'Sending'**
  String get chatStatusSending;

  /// No description provided for @chatStatusDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get chatStatusDelivered;

  /// No description provided for @chatStatusNotSent.
  ///
  /// In en, this message translates to:
  /// **'Not sent'**
  String get chatStatusNotSent;

  /// No description provided for @chatStatusNotSentNoAnswer.
  ///
  /// In en, this message translates to:
  /// **'Not sent: {name} did not answer.'**
  String chatStatusNotSentNoAnswer(String name);

  /// No description provided for @chatEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'No messages yet. Messages are end-to-end encrypted and reach them even when their app is in the background.'**
  String get chatEmptyHint;

  /// No description provided for @chatDirectNote.
  ///
  /// In en, this message translates to:
  /// **'Messages are end-to-end encrypted. They go directly between your devices, or sealed through the relay, which holds them for at most a minute and cannot read them.'**
  String get chatDirectNote;

  /// No description provided for @chatRelayNote.
  ///
  /// In en, this message translates to:
  /// **'Hide my IP is on, so messages go through the Sotto server instead of directly between your devices.'**
  String get chatRelayNote;

  /// No description provided for @chatEmptyHintRelay.
  ///
  /// In en, this message translates to:
  /// **'No messages yet. Hide my IP is on, so messages go through the Sotto server.'**
  String get chatEmptyHintRelay;

  /// No description provided for @chatDeleteMenu.
  ///
  /// In en, this message translates to:
  /// **'Delete chat'**
  String get chatDeleteMenu;

  /// No description provided for @chatDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this chat?'**
  String get chatDeleteTitle;

  /// No description provided for @chatDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'The messages are removed from this device. The other person keeps their copy.'**
  String get chatDeleteBody;

  /// No description provided for @chatCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get chatCancel;

  /// No description provided for @chatDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get chatDelete;

  /// No description provided for @chatFailConnection.
  ///
  /// In en, this message translates to:
  /// **'The connection could not be made. Your messages were not sent; you can retry.'**
  String get chatFailConnection;

  /// No description provided for @chatFailDeclined.
  ///
  /// In en, this message translates to:
  /// **'They cannot receive messages from you.'**
  String get chatFailDeclined;

  /// No description provided for @chatFailNoRelay.
  ///
  /// In en, this message translates to:
  /// **'Hide my IP address is on, but this server has no relay for chats. Turn it off, or ask the operator to add one.'**
  String get chatFailNoRelay;

  /// No description provided for @chatEnded.
  ///
  /// In en, this message translates to:
  /// **'The chat has ended.'**
  String get chatEnded;

  /// No description provided for @chatDismiss.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get chatDismiss;

  /// No description provided for @chatNoticeAnonymousTitle.
  ///
  /// In en, this message translates to:
  /// **'New message'**
  String get chatNoticeAnonymousTitle;

  /// No description provided for @chatNoticeNamedTitle.
  ///
  /// In en, this message translates to:
  /// **'New message from {name}'**
  String chatNoticeNamedTitle(String name);

  /// No description provided for @chatNoticeBody.
  ///
  /// In en, this message translates to:
  /// **'Open Sotto to read it.'**
  String get chatNoticeBody;

  /// No description provided for @chatCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy text'**
  String get chatCopy;

  /// No description provided for @chatCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get chatCopied;

  /// No description provided for @chatDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete message'**
  String get chatDeleteMessage;

  /// No description provided for @chatDeleteMessageTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this message?'**
  String get chatDeleteMessageTitle;

  /// No description provided for @chatDeleteMessageBody.
  ///
  /// In en, this message translates to:
  /// **'This message will be removed from this device. The other person keeps their copy.'**
  String get chatDeleteMessageBody;

  /// No description provided for @chatOpenLinkTitle.
  ///
  /// In en, this message translates to:
  /// **'Open external link?'**
  String get chatOpenLinkTitle;

  /// No description provided for @chatOpenLinkBody.
  ///
  /// In en, this message translates to:
  /// **'Do you want to open {url} in your browser?'**
  String chatOpenLinkBody(String url);

  /// No description provided for @chatOpenLink.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get chatOpenLink;

  /// No description provided for @chatStatusQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get chatStatusQueued;

  /// No description provided for @chatQueue.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get chatQueue;

  /// No description provided for @chatCancelQueue.
  ///
  /// In en, this message translates to:
  /// **'Cancel queue'**
  String get chatCancelQueue;

  /// No description provided for @chatCallCompanionTooltip.
  ///
  /// In en, this message translates to:
  /// **'In-call chat'**
  String get chatCallCompanionTooltip;

  /// No description provided for @chatStatusRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get chatStatusRead;

  /// No description provided for @chatDayToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get chatDayToday;

  /// No description provided for @chatDayYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get chatDayYesterday;

  /// No description provided for @chatVerifiedTooltip.
  ///
  /// In en, this message translates to:
  /// **'You confirmed this safety number'**
  String get chatVerifiedTooltip;

  /// No description provided for @chatDisappearingActive.
  ///
  /// In en, this message translates to:
  /// **'Disappearing messages: {duration} timer active'**
  String chatDisappearingActive(String duration);

  /// No description provided for @chatRetentionMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {{count} minute} other {{count} minutes}}'**
  String chatRetentionMinutes(int count);

  /// No description provided for @chatRetentionHours.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {{count} hour} other {{count} hours}}'**
  String chatRetentionHours(int count);

  /// No description provided for @chatRetentionDays.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {{count} day} other {{count} days}}'**
  String chatRetentionDays(int count);

  /// No description provided for @chatFileOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open file'**
  String get chatFileOpenFailed;

  /// No description provided for @chatFileSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save file'**
  String get chatFileSaveFailed;

  /// No description provided for @chatBubbleSemanticsOwn.
  ///
  /// In en, this message translates to:
  /// **'You, {time}, {status}: {text}'**
  String chatBubbleSemanticsOwn(String time, String status, String text);

  /// No description provided for @chatBubbleSemanticsOther.
  ///
  /// In en, this message translates to:
  /// **'{name}, {time}: {text}'**
  String chatBubbleSemanticsOther(String name, String time, String text);

  /// No description provided for @chatVoiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Voice message'**
  String get chatVoiceMessage;

  /// No description provided for @chatStatusReceiving.
  ///
  /// In en, this message translates to:
  /// **'Receiving'**
  String get chatStatusReceiving;

  /// No description provided for @chatTyping.
  ///
  /// In en, this message translates to:
  /// **'{name} is typing…'**
  String chatTyping(String name);

  /// No description provided for @privacySendTypingTitle.
  ///
  /// In en, this message translates to:
  /// **'Send typing indicators'**
  String get privacySendTypingTitle;

  /// No description provided for @privacySendTypingDesc.
  ///
  /// In en, this message translates to:
  /// **'Let contacts see when you are writing a message in real-time.'**
  String get privacySendTypingDesc;

  /// No description provided for @privacySendReadReceiptsTitle.
  ///
  /// In en, this message translates to:
  /// **'Send read receipts'**
  String get privacySendReadReceiptsTitle;

  /// No description provided for @privacySendReadReceiptsDesc.
  ///
  /// In en, this message translates to:
  /// **'Let contacts see when you have read their messages.'**
  String get privacySendReadReceiptsDesc;

  /// No description provided for @chatDisappearingTitle.
  ///
  /// In en, this message translates to:
  /// **'Disappearing messages'**
  String get chatDisappearingTitle;

  /// No description provided for @chatDisappearingDesc.
  ///
  /// In en, this message translates to:
  /// **'Automatically erase messages in this chat after the chosen duration.'**
  String get chatDisappearingDesc;

  /// No description provided for @chatDisappearingOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get chatDisappearingOff;

  /// No description provided for @chatDisappearing24h.
  ///
  /// In en, this message translates to:
  /// **'24 hours'**
  String get chatDisappearing24h;

  /// No description provided for @chatDisappearing7d.
  ///
  /// In en, this message translates to:
  /// **'7 days'**
  String get chatDisappearing7d;

  /// No description provided for @chatDisappearing30d.
  ///
  /// In en, this message translates to:
  /// **'30 days'**
  String get chatDisappearing30d;

  /// No description provided for @chatSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get chatSearch;

  /// No description provided for @chatSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search in conversation'**
  String get chatSearchHint;

  /// No description provided for @chatSearchNoMatches.
  ///
  /// In en, this message translates to:
  /// **'No matching messages found'**
  String get chatSearchNoMatches;

  /// No description provided for @chatAttachFile.
  ///
  /// In en, this message translates to:
  /// **'Attach file'**
  String get chatAttachFile;

  /// No description provided for @chatFileOffer.
  ///
  /// In en, this message translates to:
  /// **'File offered: {name}'**
  String chatFileOffer(String name);

  /// No description provided for @chatFileAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get chatFileAccept;

  /// No description provided for @chatFileDecline.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get chatFileDecline;

  /// No description provided for @chatFileDownloading.
  ///
  /// In en, this message translates to:
  /// **'Receiving {percent}%'**
  String chatFileDownloading(int percent);

  /// No description provided for @chatFileUploading.
  ///
  /// In en, this message translates to:
  /// **'Sending {percent}%'**
  String chatFileUploading(int percent);

  /// No description provided for @chatFileReceived.
  ///
  /// In en, this message translates to:
  /// **'Received file'**
  String get chatFileReceived;

  /// No description provided for @chatFileUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This file is no longer on this device.'**
  String get chatFileUnavailable;

  /// No description provided for @chatFileUnreadable.
  ///
  /// In en, this message translates to:
  /// **'This file could not be opened.'**
  String get chatFileUnreadable;

  /// No description provided for @chatFileSent.
  ///
  /// In en, this message translates to:
  /// **'Sent file'**
  String get chatFileSent;

  /// No description provided for @chatFileOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get chatFileOpen;

  /// No description provided for @chatFileSaveAs.
  ///
  /// In en, this message translates to:
  /// **'Save to…'**
  String get chatFileSaveAs;

  /// No description provided for @chatFileDeclined.
  ///
  /// In en, this message translates to:
  /// **'Transfer declined'**
  String get chatFileDeclined;

  /// No description provided for @chatFileCancelled.
  ///
  /// In en, this message translates to:
  /// **'Transfer cancelled'**
  String get chatFileCancelled;

  /// No description provided for @chatFileFailed.
  ///
  /// In en, this message translates to:
  /// **'Transfer failed'**
  String get chatFileFailed;

  /// No description provided for @chatFileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'File exceeds maximum size limit (100 MB)'**
  String get chatFileTooLarge;

  /// No description provided for @chatFileBlocked.
  ///
  /// In en, this message translates to:
  /// **'Executables and script files cannot be sent'**
  String get chatFileBlocked;

  /// No description provided for @chatImageUnreadable.
  ///
  /// In en, this message translates to:
  /// **'This image could not be read, so it was not sent.'**
  String get chatImageUnreadable;

  /// No description provided for @chatImageUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This image type cannot be sent. Save it as a JPEG or PNG and try again.'**
  String get chatImageUnsupported;

  /// No description provided for @chatVoiceRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording {time}'**
  String chatVoiceRecording(String time);

  /// No description provided for @chatVoiceCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel recording'**
  String get chatVoiceCancel;

  /// No description provided for @chatVoiceSend.
  ///
  /// In en, this message translates to:
  /// **'Send voice message'**
  String get chatVoiceSend;

  /// No description provided for @chatVoiceTooLong.
  ///
  /// In en, this message translates to:
  /// **'Recording stopped at the 5-minute limit. Send it or cancel.'**
  String get chatVoiceTooLong;

  /// No description provided for @chatVoicePermission.
  ///
  /// In en, this message translates to:
  /// **'Sotto needs permission to use the microphone. Allow it in your device settings, then try again.'**
  String get chatVoicePermission;

  /// No description provided for @chatVoiceMicPrivacy.
  ///
  /// In en, this message translates to:
  /// **'No sound came from the microphone. Check microphone privacy settings in Windows, then try again. Nothing was sent.'**
  String get chatVoiceMicPrivacy;

  /// No description provided for @chatVoiceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Voice message unavailable'**
  String get chatVoiceUnavailable;

  /// No description provided for @chatVoiceNeedsParecord.
  ///
  /// In en, this message translates to:
  /// **'Voice messages on Linux need the pulseaudio-utils package, which provides parecord. Install it, then try again.'**
  String get chatVoiceNeedsParecord;

  /// No description provided for @chatVoiceInCall.
  ///
  /// In en, this message translates to:
  /// **'Voice messages are not available during a call.'**
  String get chatVoiceInCall;

  /// No description provided for @chatVoicePlay.
  ///
  /// In en, this message translates to:
  /// **'Play voice message'**
  String get chatVoicePlay;

  /// No description provided for @chatVoicePause.
  ///
  /// In en, this message translates to:
  /// **'Pause voice message'**
  String get chatVoicePause;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'bn', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'bn':
      return AppLocalizationsBn();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
