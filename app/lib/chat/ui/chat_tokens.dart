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

  /// The light theme's chat colours.
  static const ChatTokens light = ChatTokens(
    body: Color(0xFFF1F3F5),
    header: Color(0xFFF8F9FA),
    footer: Color(0xFFFFFFFF),
    divider: Color(0xFFE5E7EB),
    sentFill: Color(0xFF5B4B8A),
    sentText: Color(0xFFFFFFFF),
    sentSecondary: Color(0xFFE6E0F3),
    sentFileTile: Color(0xFF6D5E9C),
    notSentIcon: Color(0xFFFFB4AB),
    receivedFill: Color(0xFFFFFFFF),
    receivedText: Color(0xFF16161D),
    receivedSecondary: Color(0xFF5D5B68),
    receivedBorder: Color(0xFFE5E7EB),
    receivedLink: Color(0xFF5B4B8A),
    receivedFileTile: Color(0xFFF1F3F5),
    receivedFileIcon: Color(0xFF16161D),
    headerTitle: Color(0xFF16161D),
    headerSubtitle: Color(0xFF5D5B68),
    headerIcon: Color(0xFF5D5B68),
    verifiedIcon: Color(0xFF5B4B8A),
    dayChipFill: Color(0xFFE3E4E8),
    dayChipText: Color(0xFF5D5B68),
    typingFill: Color(0xFFE3E4E8),
    typingText: Color(0xFF5D5B68),
    spinner: Color(0xFF5B4B8A),
    pillFill: Color(0xFFE3E4E8),
    pillText: Color(0xFF16161D),
    pillIcon: Color(0xFF5B4B8A),
    fieldFill: Color(0xFFF1F3F5),
    fieldText: Color(0xFF16161D),
    fieldHint: Color(0xFF5D5B68),
    attachIcon: Color(0xFF5D5B68),
    footerNote: Color(0xFF5D5B68),
    sendFill: Color(0xFF5B4B8A),
    sendIcon: Color(0xFFFFFFFF),
    acceptFill: Color(0xFFE8DEF8),
    acceptText: Color(0xFF494458),
    bannerFill: Color(0xFFFFDAD6),
    bannerText: Color(0xFF93000A),
  );

  /// The dark theme's chat colours.
  static const ChatTokens dark = ChatTokens(
    body: Color(0xFF09090D),
    header: Color(0xFF09090D),
    footer: Color(0xFF0F0F14),
    divider: Color(0xFF2A2A34),
    sentFill: Color(0xFF4D3F86),
    sentText: Color(0xFFFFFFFF),
    sentSecondary: Color(0xFFD9D2EF),
    sentFileTile: Color(0xFF5E4F9C),
    notSentIcon: Color(0xFFFFB4AB),
    receivedFill: Color(0xFF14141B),
    receivedText: Color(0xFFF0EFF5),
    receivedSecondary: Color(0xFFA6A4B4),
    receivedBorder: Color(0xFF2A2A34),
    receivedLink: Color(0xFF9E8CF4),
    receivedFileTile: Color(0xFF20202A),
    receivedFileIcon: Color(0xFFF0EFF5),
    headerTitle: Color(0xFFF0EFF5),
    headerSubtitle: Color(0xFFA6A4B4),
    headerIcon: Color(0xFFA6A4B4),
    verifiedIcon: Color(0xFF9E8CF4),
    dayChipFill: Color(0xFF20202A),
    dayChipText: Color(0xFFA6A4B4),
    typingFill: Color(0xFF20202A),
    typingText: Color(0xFFA6A4B4),
    spinner: Color(0xFF9E8CF4),
    pillFill: Color(0xFF191922),
    pillText: Color(0xFFF0EFF5),
    pillIcon: Color(0xFF9E8CF4),
    fieldFill: Color(0xFF191922),
    fieldText: Color(0xFFF0EFF5),
    fieldHint: Color(0xFFA6A4B4),
    attachIcon: Color(0xFFA6A4B4),
    footerNote: Color(0xFFA6A4B4),
    sendFill: Color(0xFF9E8CF4),
    sendIcon: Color(0xFF1B1438),
    acceptFill: Color(0xFF494458),
    acceptText: Color(0xFFE8DEF8),
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
