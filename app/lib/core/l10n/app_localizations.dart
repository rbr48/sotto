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

  /// No description provided for @navHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

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

  /// No description provided for @chatStatusNotSentOffline.
  ///
  /// In en, this message translates to:
  /// **'Not sent: {name} is offline'**
  String chatStatusNotSentOffline(String name);

  /// No description provided for @chatEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'No messages yet. Messages go directly to them while you are both online.'**
  String get chatEmptyHint;

  /// No description provided for @chatDirectNote.
  ///
  /// In en, this message translates to:
  /// **'Messages go directly between your devices while you are both online. Nothing is stored on a server.'**
  String get chatDirectNote;

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
