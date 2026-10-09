import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/ui/chat_tokens.dart';
import 'package:sotto/core/theme.dart';

/// WCAG 2.x relative luminance of an opaque colour.
double _luminance(Color color) {
  double linear(double channel) => channel <= 0.03928
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * linear(color.r) +
      0.7152 * linear(color.g) +
      0.0722 * linear(color.b);
}

/// WCAG 2.x contrast ratio between two opaque colours, from 1 to 21.
double _contrastRatio(Color a, Color b) {
  final lighter = math.max(_luminance(a), _luminance(b));
  final darker = math.min(_luminance(a), _luminance(b));
  return (lighter + 0.05) / (darker + 0.05);
}

typedef _Pick = Color Function(ChatTokens tokens);

/// Every text the chat screen draws, with the fill it is drawn on.
final List<(String, _Pick, _Pick)> _textPairs = [
  ('contact name in the app bar', (t) => t.headerTitle, (t) => t.header),
  ('connection line in the app bar', (t) => t.headerSubtitle, (t) => t.header),
  ('day separator', (t) => t.dayChipText, (t) => t.dayChipFill),
  ('typing indicator', (t) => t.typingText, (t) => t.typingFill),
  ('disappearing-messages pill', (t) => t.pillText, (t) => t.pillFill),
  ('text in the message field', (t) => t.fieldText, (t) => t.fieldFill),
  ('hint in the message field', (t) => t.fieldHint, (t) => t.fieldFill),
  ('note above the message field', (t) => t.footerNote, (t) => t.footer),
  ('text you sent', (t) => t.sentText, (t) => t.sentFill),
  ('time and status you sent', (t) => t.sentSecondary, (t) => t.sentFill),
  ('text you received', (t) => t.receivedText, (t) => t.receivedFill),
  ('time you received', (t) => t.receivedSecondary, (t) => t.receivedFill),
  ('link you received', (t) => t.receivedLink, (t) => t.receivedFill),
  ('problem banner', (t) => t.bannerText, (t) => t.bannerFill),
  ('Accept button', (t) => t.acceptText, (t) => t.acceptFill),
];

/// Every icon the chat screen draws, with the fill it sits on. Icons need 3:1.
final List<(String, _Pick, _Pick)> _iconPairs = [
  ('app bar icons', (t) => t.headerIcon, (t) => t.header),
  ('verified badge', (t) => t.verifiedIcon, (t) => t.header),
  ('pill icon', (t) => t.pillIcon, (t) => t.pillFill),
  ('typing spinner', (t) => t.spinner, (t) => t.typingFill),
  ('attach icon', (t) => t.attachIcon, (t) => t.footer),
  ('send and voice icon', (t) => t.sendIcon, (t) => t.sendFill),
  ('not-sent icon', (t) => t.notSentIcon, (t) => t.sentFill),
  (
    'file icon you received',
    (t) => t.receivedFileIcon,
    (t) => t.receivedFileTile,
  ),
  ('file icon you sent', (t) => t.sentText, (t) => t.sentFileTile),
];

void main() {
  for (final (mode, tokens) in [
    ('light', ChatTokens.light),
    ('dark', ChatTokens.dark),
  ]) {
    group('$mode theme contrast', () {
      for (final (label, text, fill) in _textPairs) {
        test('$label is at least 4.5:1', () {
          final ratio = _contrastRatio(text(tokens), fill(tokens));
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: '$label is ${ratio.toStringAsFixed(2)}:1',
          );
        });
      }
      for (final (label, icon, fill) in _iconPairs) {
        test('$label is at least 3:1', () {
          final ratio = _contrastRatio(icon(tokens), fill(tokens));
          expect(
            ratio,
            greaterThanOrEqualTo(3.0),
            reason: '$label is ${ratio.toStringAsFixed(2)}:1',
          );
        });
      }
    });
  }

  test('both app themes carry the matching chat colours', () {
    expect(SottoTheme.light().extension<ChatTokens>(), same(ChatTokens.light));
    expect(SottoTheme.dark().extension<ChatTokens>(), same(ChatTokens.dark));
  });

  testWidgets('a theme without the extension falls back by brightness', (
    tester,
  ) async {
    late ChatTokens inDark;
    late ChatTokens inLight;
    await tester.pumpWidget(
      Column(
        children: [
          Theme(
            data: ThemeData(brightness: Brightness.dark),
            child: Builder(
              builder: (context) {
                inDark = ChatTokens.of(context);
                return const SizedBox();
              },
            ),
          ),
          Theme(
            data: ThemeData(brightness: Brightness.light),
            child: Builder(
              builder: (context) {
                inLight = ChatTokens.of(context);
                return const SizedBox();
              },
            ),
          ),
        ],
      ),
    );
    expect(inDark, same(ChatTokens.dark));
    expect(inLight, same(ChatTokens.light));
  });

  test('copyWith changes only the tokens given', () {
    const changed = Color(0xFF123456);
    final copy = ChatTokens.light.copyWith(sentFill: changed);
    expect(copy.sentFill, changed);
    expect(copy.receivedFill, ChatTokens.light.receivedFill);
    expect(copy.bannerText, ChatTokens.light.bannerText);
  });

  test('lerp moves between the two sets and keeps the ends', () {
    final start = ChatTokens.light.lerp(ChatTokens.dark, 0);
    final end = ChatTokens.light.lerp(ChatTokens.dark, 1);
    final middle = ChatTokens.light.lerp(ChatTokens.dark, 0.5);
    expect(start.body, ChatTokens.light.body);
    expect(end.body, ChatTokens.dark.body);
    expect(end.sentFill, ChatTokens.dark.sentFill);
    expect(
      middle.body,
      Color.lerp(ChatTokens.light.body, ChatTokens.dark.body, 0.5),
    );
  });

  test('lerp with another extension type returns the same tokens', () {
    expect(ChatTokens.light.lerp(null, 0.5), same(ChatTokens.light));
  });
}
