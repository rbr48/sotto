import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/chat_page.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';
import 'package:sotto/core/theme.dart';
import 'package:sotto/crypto/identity_store.dart';

ChatMessage _message(
  String text, {
  required bool outgoing,
  required ChatState state,
  String? reason,
}) => ChatMessage(
  id: ChatFrames.newId(),
  contactId: 'bob',
  outgoing: outgoing,
  ts: 1700000000000,
  text: text,
  state: state,
  reason: reason,
);

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

void main() {
  late ChatStore store;
  late ChatManager chat;

  setUp(() {
    store = ChatStore(MemorySecretStore());
    chat = ChatManager(
      myId: 'alice',
      store: store,
      isContact: {'bob'}.contains,
      send: (to, type, body, callId) {},
      iceServers: () async => const [],
      hideIp: () => false,
      createRtc: ({required iceServers, required relayOnly}) async =>
          throw StateError('no connection in this test'),
      clock: DateTime.now,
    );
  });

  tearDown(() async {
    await chat.dispose();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    ThemeData? theme,
    String name = 'Bob',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        locale: AppLanguage.english.locale,
        supportedLocales: AppLanguage.supported,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ChatPage(chat: chat, contactId: 'bob', name: name),
      ),
    );
    // The store is read asynchronously; let it finish.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }

  testWidgets('shows both sides of the chat, with the state of each message', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await store.add(
        _message('Hello there', outgoing: true, state: ChatState.delivered),
      );
      await store.add(
        _message('Hi from Bob', outgoing: false, state: ChatState.received),
      );
      await store.add(
        _message('Lost in transit', outgoing: true, state: ChatState.notSent),
      );
    });

    await pumpPage(tester);

    expect(find.text('Hello there'), findsOneWidget);
    expect(find.text('Hi from Bob'), findsOneWidget);
    expect(find.text('Lost in transit'), findsOneWidget);
    expect(find.text('Delivered'), findsOneWidget);
    expect(find.text('Not sent'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('an empty chat says where messages go', (tester) async {
    await pumpPage(tester);
    expect(
      find.text(
        'No messages yet. Messages go directly to them while you are both online.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('writing a message stores it and shows it as sending', (
    tester,
  ) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'Salaam');
    await tester.tap(find.byTooltip('Send'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    expect(find.text('Salaam'), findsOneWidget);
    expect(find.text('Sending'), findsOneWidget);
    final stored = await tester.runAsync(() => store.messages('bob'));
    expect(stored!.single.text, 'Salaam');

    // Sending starts the chat's periodic check: stop it before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(chat.dispose);
  });

  testWidgets('an unsent message to someone who is offline says so, by name', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await store.add(
        _message(
          'Are you there?',
          outgoing: true,
          state: ChatState.notSent,
          reason: 'no-answer',
        ),
      );
      await store.add(
        _message(
          'Sent elsewhere',
          outgoing: true,
          state: ChatState.notSent,
          reason: 'declined',
        ),
      );
    });

    await pumpPage(tester);

    // Nobody answered the open: the plan's wording, with the name.
    expect(find.text('Not sent: Bob is offline'), findsOneWidget);
    // Any other failure says only "Not sent"; the banner explains it.
    expect(find.text('Not sent'), findsOneWidget);
  });

  testWidgets('a long name and its status fit a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await store.add(
        _message(
          'Are you there?',
          outgoing: true,
          state: ChatState.notSent,
          reason: 'no-answer',
        ),
      );
    });

    await pumpPage(tester, name: 'Muhammad Abdul Rahman Al-Hashimi');

    expect(tester.takeException(), isNull);
    expect(find.text('Retry'), findsOneWidget);
    expect(
      find.text('Not sent: Muhammad Abdul Rahman Al-Hashimi is offline'),
      findsOneWidget,
    );
  });

  testWidgets(
    'Retry is readable on an unsent message in light and dark themes',
    (tester) async {
      await tester.runAsync(() async {
        await store.add(
          _message('Lost in transit', outgoing: true, state: ChatState.notSent),
        );
      });

      for (final theme in [SottoTheme.light(), SottoTheme.dark()]) {
        await pumpPage(tester, theme: theme);
        final scheme = theme.colorScheme;

        // What is painted, not what the button is configured with: the label's
        // text colour, and the fill of the bubble behind it (its nearest
        // Container with a BoxDecoration).
        final label = DefaultTextStyle.of(tester.element(find.text('Retry')))
            .style
            .color;
        final background = tester
            .widgetList<Container>(
              find.ancestor(
                of: find.text('Lost in transit'),
                matching: find.byType(Container),
              ),
            )
            .map((container) => container.decoration)
            .whereType<BoxDecoration>()
            .first
            .color;
        expect(label, isNotNull, reason: 'the Retry label has no colour');
        expect(label, scheme.onPrimary);
        expect(
          background,
          scheme.primary,
          reason: 'the bubble is not the primary colour',
        );
        expect(_contrastRatio(label!, background!), greaterThanOrEqualTo(4.5));

        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}
