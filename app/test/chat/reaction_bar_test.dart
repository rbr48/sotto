import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/ui/reaction_bar.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';
import 'package:sotto/core/theme.dart';

void main() {
  Future<List<String>> pumpBar(
    WidgetTester tester, {
    Map<String, String> reactions = const {},
    bool choosing = false,
  }) async {
    final reacted = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: SottoTheme.light(),
        locale: AppLanguage.english.locale,
        supportedLocales: AppLanguage.supported,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: ReactionBar(
            reactions: reactions,
            peerName: 'Bob',
            choosing: choosing,
            onReact: reacted.add,
          ),
        ),
      ),
    );
    return reacted;
  }

  testWidgets('shows nothing without reactions and when not choosing', (
    tester,
  ) async {
    await pumpBar(tester);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byIcon(Icons.add_reaction_outlined), findsNothing);
  });

  testWidgets('each reaction shows its emoji, announced with whose it is', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpBar(tester, reactions: {'me': '👍', 'peer': '❤️'});

    expect(find.text('👍'), findsOneWidget);
    expect(find.text('❤️'), findsOneWidget);
    expect(find.bySemanticsLabel('👍, You'), findsOneWidget);
    expect(find.bySemanticsLabel('❤️, Bob'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('tapping your own reaction sends the empty emoji to remove it', (
    tester,
  ) async {
    final reacted = await pumpBar(tester, reactions: {'me': '👍'});
    await tester.tap(find.text('👍'));
    await tester.pump();
    expect(reacted, ['']);
  });

  testWidgets(
    'tapping the other person\'s reaction sets yours to the same emoji',
    (tester) async {
      final reacted = await pumpBar(tester, reactions: {'peer': '😂'});
      await tester.tap(find.text('😂'));
      await tester.pump();
      expect(reacted, ['😂']);
    },
  );

  testWidgets('choosing shows the quick emoji, and a tap sets one', (
    tester,
  ) async {
    final reacted = await pumpBar(tester, choosing: true);
    for (final emoji in ReactionBar.quickEmoji) {
      expect(find.text(emoji), findsOneWidget, reason: emoji);
    }
    await tester.tap(find.text('😮'));
    await tester.pump();
    expect(reacted, ['😮']);
  });

  testWidgets('the more button opens the full picker, and its emoji is set', (
    tester,
  ) async {
    final reacted = await pumpBar(tester, choosing: true);
    await tester.tap(find.byIcon(Icons.add_reaction_outlined));
    await tester.pumpAndSettle();

    // The first emoji of the smileys grid.
    await tester.tap(find.text('😀'));
    await tester.pumpAndSettle();
    expect(reacted, ['😀']);
    // The reaction sheet has no backspace key: nothing to delete there.
    expect(find.byIcon(Icons.backspace_outlined), findsNothing);
  });

  testWidgets('the more button sets nothing when the picker is dismissed', (
    tester,
  ) async {
    final reacted = await pumpBar(tester, choosing: true);
    await tester.tap(find.byIcon(Icons.add_reaction_outlined));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(reacted, isEmpty);
  });
}
