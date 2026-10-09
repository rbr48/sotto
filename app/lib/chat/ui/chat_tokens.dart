import 'package:flutter/material.dart';

/// Colours of the chat screen only, in light and dark.
///
/// The app's palette lives in core/theme.dart. These values repeat part of it
/// on purpose, so the chat screen can be checked on its own. test/chat/
/// chat_tokens_test.dart holds every text pair to 4.5:1 and every icon pair to
/// 3:1, which catches drift that would make the screen hard to read.
///
/// A theme without this extension still works: [ChatTokens.of] picks [light]
/// or [dark] by brightness.
@immutable
class ChatTokens extends ThemeExtension<ChatTokens> {
  const ChatTokens({
    required this.body,
    required this.header,
    required this.footer,
    required this.divider,
    required this.sentFill,
    required this.sentText,
    required this.sentSecondary,
    required this.sentFileTile,
    required this.notSentIcon,
    required this.receivedFill,
    required this.receivedText,
    required this.receivedSecondary,
    required this.receivedBorder,
    required this.receivedLink,
    required this.receivedFileTile,
    required this.receivedFileIcon,
    required this.headerTitle,
    required this.headerSubtitle,
    required this.headerIcon,
    required this.verifiedIcon,
    required this.dayChipFill,
    required this.dayChipText,
    required this.typingFill,
    required this.typingText,
    required this.spinner,
    required this.pillFill,
    required this.pillText,
    required this.pillIcon,
    required this.fieldFill,
    required this.fieldText,
    required this.fieldHint,
    required this.attachIcon,
    required this.footerNote,
    required this.sendFill,
    required this.sendIcon,
    required this.acceptFill,
    required this.acceptText,
    required this.bannerFill,
    required this.bannerText,
  });

  /// The light theme's chat colours (WhatsApp-inspired premium skin).
  static const ChatTokens light = ChatTokens(
    body: Color(0xFFEFEAE2),
    header: Color(0xFFFFFFFF),
    footer: Color(0xFFF0F2F5),
    divider: Color(0xFFE2E5E9),
    sentFill: Color(0xFFD9FDD3),
    sentText: Color(0xFF111B21),
    sentSecondary: Color(0xFF486150),
    sentFileTile: Color(0xFFC3EEBD),
    notSentIcon: Color(0xFFBA1A1A),
    receivedFill: Color(0xFFFFFFFF),
    receivedText: Color(0xFF111B21),
    receivedSecondary: Color(0xFF54656F),
    receivedBorder: Color(0xFFE2E5E9),
    receivedLink: Color(0xFF007A65),
    receivedFileTile: Color(0xFFF0F2F5),
    receivedFileIcon: Color(0xFF111B21),
    headerTitle: Color(0xFF111B21),
    headerSubtitle: Color(0xFF54656F),
    headerIcon: Color(0xFF54656F),
    verifiedIcon: Color(0xFF008069),
    dayChipFill: Color(0xFFFFFFFF),
    dayChipText: Color(0xFF54656F),
    typingFill: Color(0xFFE9EDEF),
    typingText: Color(0xFF54656F),
    spinner: Color(0xFF008069),
    pillFill: Color(0xFFE9EDEF),
    pillText: Color(0xFF111B21),
    pillIcon: Color(0xFF008069),
    fieldFill: Color(0xFFFFFFFF),
    fieldText: Color(0xFF111B21),
    fieldHint: Color(0xFF54656F),
    attachIcon: Color(0xFF54656F),
    footerNote: Color(0xFF54656F),
    sendFill: Color(0xFF00A884),
    sendIcon: Color(0xFFFFFFFF),
    acceptFill: Color(0xFFDCF8C6),
    acceptText: Color(0xFF075E54),
    bannerFill: Color(0xFFFFDAD6),
    bannerText: Color(0xFF93000A),
  );

  /// The dark theme's chat colours (WhatsApp-inspired premium dark skin).
  static const ChatTokens dark = ChatTokens(
    body: Color(0xFF0B141A),
    header: Color(0xFF1F2C34),
    footer: Color(0xFF1F2C34),
    divider: Color(0xFF2A3942),
    sentFill: Color(0xFF005C4B),
    sentText: Color(0xFFE9EDEF),
    sentSecondary: Color(0xFF8AD4C4),
    sentFileTile: Color(0xFF024B3D),
    notSentIcon: Color(0xFFFFB4AB),
    receivedFill: Color(0xFF202C33),
    receivedText: Color(0xFFE9EDEF),
    receivedSecondary: Color(0xFF8696A0),
    receivedBorder: Color(0xFF2A3942),
    receivedLink: Color(0xFF53BDEB),
    receivedFileTile: Color(0xFF2A3942),
    receivedFileIcon: Color(0xFFE9EDEF),
    headerTitle: Color(0xFFE9EDEF),
    headerSubtitle: Color(0xFF8696A0),
    headerIcon: Color(0xFF8696A0),
    verifiedIcon: Color(0xFF00A884),
    dayChipFill: Color(0xFF182229),
    dayChipText: Color(0xFF8696A0),
    typingFill: Color(0xFF182229),
    typingText: Color(0xFF8696A0),
    spinner: Color(0xFF00A884),
    pillFill: Color(0xFF182229),
    pillText: Color(0xFFE9EDEF),
    pillIcon: Color(0xFF00A884),
    fieldFill: Color(0xFF2A3942),
    fieldText: Color(0xFFE9EDEF),
    fieldHint: Color(0xFFA2B2BD),
    attachIcon: Color(0xFF8696A0),
    footerNote: Color(0xFF8696A0),
    sendFill: Color(0xFF00A884),
    sendIcon: Color(0xFFFFFFFF),
    acceptFill: Color(0xFF005C4B),
    acceptText: Color(0xFF8AD4C4),
    bannerFill: Color(0xFF93000A),
    bannerText: Color(0xFFFFDAD6),
  );

  /// The chat colours of the theme in use, or the light or dark set when the
  /// theme does not carry them.
  static ChatTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ChatTokens>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  /// Background of the conversation.
  final Color body;

  /// Background of the app bar.
  final Color header;

  /// Background of the composer area.
  final Color footer;

  /// Hairline between the app bar and the body, and above the composer.
  final Color divider;

  /// Fill of a message you sent.
  final Color sentFill;

  /// Text and icons on a message you sent.
  final Color sentText;

  /// Time and status on a message you sent.
  final Color sentSecondary;

  /// Icon tile of a file you sent.
  final Color sentFileTile;

  /// Icon of a message that was not sent.
  final Color notSentIcon;

  /// Fill of a message you received.
  final Color receivedFill;

  /// Text on a message you received.
  final Color receivedText;

  /// Time on a message you received.
  final Color receivedSecondary;

  /// Border of a message you received.
  final Color receivedBorder;

  /// Links in a message you received.
  final Color receivedLink;

  /// Icon tile of a file you received.
  final Color receivedFileTile;

  /// Icon of a file you received.
  final Color receivedFileIcon;

  /// Contact name in the app bar.
  final Color headerTitle;

  /// Connection line in the app bar (v1.1 only).
  final Color headerSubtitle;

  /// Icons in the app bar.
  final Color headerIcon;

  /// Verified badge next to the contact name.
  final Color verifiedIcon;

  /// Fill of a day separator.
  final Color dayChipFill;

  /// Text of a day separator.
  final Color dayChipText;

  /// Fill of the typing indicator.
  final Color typingFill;

  /// Text of the typing indicator.
  final Color typingText;

  /// Spinner of the typing indicator.
  final Color spinner;

  /// Fill of the disappearing-messages pill.
  final Color pillFill;

  /// Text of the disappearing-messages pill.
  final Color pillText;

  /// Icon of the disappearing-messages pill.
  final Color pillIcon;

  /// Fill of the message field.
  final Color fieldFill;

  /// Text typed in the message field.
  final Color fieldText;

  /// Hint in the message field.
  final Color fieldHint;

  /// Attach button icon.
  final Color attachIcon;

  /// Note above the message field.
  final Color footerNote;

  /// Fill of the send or voice button.
  final Color sendFill;

  /// Icon of the send or voice button.
  final Color sendIcon;

  /// Fill of the Accept button for a file.
  final Color acceptFill;

  /// Text of the Accept button for a file.
  final Color acceptText;

  /// Fill of the problem banner.
  final Color bannerFill;

  /// Text of the problem banner.
  final Color bannerText;

  @override
  ChatTokens copyWith({
    Color? body,
    Color? header,
    Color? footer,
    Color? divider,
    Color? sentFill,
    Color? sentText,
    Color? sentSecondary,
    Color? sentFileTile,
    Color? notSentIcon,
    Color? receivedFill,
    Color? receivedText,
    Color? receivedSecondary,
    Color? receivedBorder,
    Color? receivedLink,
    Color? receivedFileTile,
    Color? receivedFileIcon,
    Color? headerTitle,
    Color? headerSubtitle,
    Color? headerIcon,
    Color? verifiedIcon,
    Color? dayChipFill,
    Color? dayChipText,
    Color? typingFill,
    Color? typingText,
    Color? spinner,
    Color? pillFill,
    Color? pillText,
    Color? pillIcon,
    Color? fieldFill,
    Color? fieldText,
    Color? fieldHint,
    Color? attachIcon,
    Color? footerNote,
    Color? sendFill,
    Color? sendIcon,
    Color? acceptFill,
    Color? acceptText,
    Color? bannerFill,
    Color? bannerText,
  }) {
    return ChatTokens(
      body: body ?? this.body,
      header: header ?? this.header,
      footer: footer ?? this.footer,
      divider: divider ?? this.divider,
      sentFill: sentFill ?? this.sentFill,
      sentText: sentText ?? this.sentText,
      sentSecondary: sentSecondary ?? this.sentSecondary,
      sentFileTile: sentFileTile ?? this.sentFileTile,
      notSentIcon: notSentIcon ?? this.notSentIcon,
      receivedFill: receivedFill ?? this.receivedFill,
      receivedText: receivedText ?? this.receivedText,
      receivedSecondary: receivedSecondary ?? this.receivedSecondary,
      receivedBorder: receivedBorder ?? this.receivedBorder,
      receivedLink: receivedLink ?? this.receivedLink,
      receivedFileTile: receivedFileTile ?? this.receivedFileTile,
      receivedFileIcon: receivedFileIcon ?? this.receivedFileIcon,
      headerTitle: headerTitle ?? this.headerTitle,
      headerSubtitle: headerSubtitle ?? this.headerSubtitle,
      headerIcon: headerIcon ?? this.headerIcon,
      verifiedIcon: verifiedIcon ?? this.verifiedIcon,
      dayChipFill: dayChipFill ?? this.dayChipFill,
      dayChipText: dayChipText ?? this.dayChipText,
      typingFill: typingFill ?? this.typingFill,
      typingText: typingText ?? this.typingText,
      spinner: spinner ?? this.spinner,
      pillFill: pillFill ?? this.pillFill,
      pillText: pillText ?? this.pillText,
      pillIcon: pillIcon ?? this.pillIcon,
      fieldFill: fieldFill ?? this.fieldFill,
      fieldText: fieldText ?? this.fieldText,
      fieldHint: fieldHint ?? this.fieldHint,
      attachIcon: attachIcon ?? this.attachIcon,
      footerNote: footerNote ?? this.footerNote,
      sendFill: sendFill ?? this.sendFill,
      sendIcon: sendIcon ?? this.sendIcon,
      acceptFill: acceptFill ?? this.acceptFill,
      acceptText: acceptText ?? this.acceptText,
      bannerFill: bannerFill ?? this.bannerFill,
      bannerText: bannerText ?? this.bannerText,
    );
  }

  @override
  ChatTokens lerp(ThemeExtension<ChatTokens>? other, double t) {
    if (other is! ChatTokens) return this;
    return ChatTokens(
      body: Color.lerp(body, other.body, t)!,
      header: Color.lerp(header, other.header, t)!,
      footer: Color.lerp(footer, other.footer, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      sentFill: Color.lerp(sentFill, other.sentFill, t)!,
      sentText: Color.lerp(sentText, other.sentText, t)!,
      sentSecondary: Color.lerp(sentSecondary, other.sentSecondary, t)!,
      sentFileTile: Color.lerp(sentFileTile, other.sentFileTile, t)!,
      notSentIcon: Color.lerp(notSentIcon, other.notSentIcon, t)!,
      receivedFill: Color.lerp(receivedFill, other.receivedFill, t)!,
      receivedText: Color.lerp(receivedText, other.receivedText, t)!,
      receivedSecondary: Color.lerp(
        receivedSecondary,
        other.receivedSecondary,
        t,
      )!,
      receivedBorder: Color.lerp(receivedBorder, other.receivedBorder, t)!,
      receivedLink: Color.lerp(receivedLink, other.receivedLink, t)!,
      receivedFileTile: Color.lerp(
        receivedFileTile,
        other.receivedFileTile,
        t,
      )!,
      receivedFileIcon: Color.lerp(
        receivedFileIcon,
        other.receivedFileIcon,
        t,
      )!,
      headerTitle: Color.lerp(headerTitle, other.headerTitle, t)!,
      headerSubtitle: Color.lerp(headerSubtitle, other.headerSubtitle, t)!,
      headerIcon: Color.lerp(headerIcon, other.headerIcon, t)!,
      verifiedIcon: Color.lerp(verifiedIcon, other.verifiedIcon, t)!,
      dayChipFill: Color.lerp(dayChipFill, other.dayChipFill, t)!,
      dayChipText: Color.lerp(dayChipText, other.dayChipText, t)!,
      typingFill: Color.lerp(typingFill, other.typingFill, t)!,
      typingText: Color.lerp(typingText, other.typingText, t)!,
      spinner: Color.lerp(spinner, other.spinner, t)!,
      pillFill: Color.lerp(pillFill, other.pillFill, t)!,
      pillText: Color.lerp(pillText, other.pillText, t)!,
      pillIcon: Color.lerp(pillIcon, other.pillIcon, t)!,
      fieldFill: Color.lerp(fieldFill, other.fieldFill, t)!,
      fieldText: Color.lerp(fieldText, other.fieldText, t)!,
      fieldHint: Color.lerp(fieldHint, other.fieldHint, t)!,
      attachIcon: Color.lerp(attachIcon, other.attachIcon, t)!,
      footerNote: Color.lerp(footerNote, other.footerNote, t)!,
      sendFill: Color.lerp(sendFill, other.sendFill, t)!,
      sendIcon: Color.lerp(sendIcon, other.sendIcon, t)!,
      acceptFill: Color.lerp(acceptFill, other.acceptFill, t)!,
      acceptText: Color.lerp(acceptText, other.acceptText, t)!,
      bannerFill: Color.lerp(bannerFill, other.bannerFill, t)!,
      bannerText: Color.lerp(bannerText, other.bannerText, t)!,
    );
  }
}
