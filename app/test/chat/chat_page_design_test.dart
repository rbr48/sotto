import 'dart:io';
import 'dart:typed_data';

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

int _ms(int year, int month, int day, [int hour = 0, int minute = 0]) =>
    DateTime(year, month, day, hour, minute).millisecondsSinceEpoch;

ChatMessage _message(
  String text, {
  required bool outgoing,
  required ChatState state,
  int? ts,
  int? arrivedAt,
  String? reason,
}) => ChatMessage(
  id: ChatFrames.newId(),
  contactId: 'bob',
  outgoing: outgoing,
  ts: ts ?? _ms(2026, 10, 9, 9),
  text: text,
  state: state,
  reason: reason,
  arrivedAt: arrivedAt,
);

ChatMessage _file({
  required bool outgoing,
  required String status,
  String? filePath,
  ChatState state = ChatState.received,
}) => ChatMessage(
  id: ChatFrames.newId(),
  contactId: 'bob',
  outgoing: outgoing,
  ts: _ms(2026, 10, 9, 9),
  text: 'report.pdf',
  state: outgoing ? ChatState.sending : state,
  fileId: ChatFrames.newId(),
  fileName: 'report.pdf',
  fileSize: 2048,
  fileMime: 'application/pdf',
  fileStatus: status,
  filePath: filePath,
  arrivedAt: outgoing ? null : _ms(2026, 10, 9, 9),
);

ChatManager _chatWith({
  ChatStore? store,
  DateTime Function()? clock,
  bool Function()? hideIp,
}) => ChatManager(
  myId: 'alice',
  store: store ?? ChatStore(MemorySecretStore()),
  isContact: {'bob'}.contains,
  send: (to, type, body, callId) {},
  iceServers: () async => const [],
  hideIp: hideIp ?? () => false,
  createRtc: ({required iceServers, required relayOnly}) async =>
      throw StateError('no connection in this test'),
  clock: clock ?? () => DateTime(2026, 10, 9, 12),
);

Future<void> _pump(
  WidgetTester tester,
  ChatManager chat, {
  String name = 'Bob',
  bool verified = false,
  Locale locale = const Locale('en'),
  double textScale = 1,
  TextDirection? direction,
  bool dark = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? SottoTheme.dark() : SottoTheme.light(),
      locale: locale,
      supportedLocales: AppLanguage.supported,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: (context, child) {
        final scaled = MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        );
        return direction == null
            ? scaled
            : Directionality(textDirection: direction, child: scaled);
      },
      home: ChatPage(
        chat: chat,
        contactId: 'bob',
        name: name,
        verified: verified,
      ),
    ),
  );
  // The store is read asynchronously; let it finish.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
}

/// A voice note, or an audio file that is not one, sent or received.
ChatMessage _audio({
  required bool outgoing,
  required String name,
  required String mime,
  required bool voiceNote,
  String status = 'completed',
}) => ChatMessage(
  id: ChatFrames.newId(),
  contactId: 'bob',
  outgoing: outgoing,
  ts: _ms(2026, 10, 9, 9),
  text: name,
  state: outgoing ? ChatState.delivered : ChatState.received,
  fileId: ChatFrames.newId(),
  fileName: name,
  fileSize: 1000,
  fileMime: mime,
  fileStatus: status,
  filePath: 'web:$name',
  voiceNote: voiceNote,
  arrivedAt: outgoing ? null : _ms(2026, 10, 9, 9),
);

/// Sets the screen to [width] by [height] logical pixels, and restores it after.
void _setScreen(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Takes the page off screen, so its timers and streams are cancelled.
Future<void> _unmount(WidgetTester tester, ChatManager chat) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(chat.dispose);
}

void main() {
  group('day separators and times (pure rules)', () {
    test('the first message shown always starts a day', () {
      expect(
        needsDaySeparator(previousClockMs: null, clockMs: _ms(2026, 10, 9, 9)),
        isTrue,
      );
    });

    test('messages on one local day share a separator', () {
      expect(
        needsDaySeparator(
          previousClockMs: _ms(2026, 10, 9, 9),
          clockMs: _ms(2026, 10, 9, 22),
        ),
        isFalse,
      );
    });

    test('a message just after midnight starts a new day', () {
      final before = DateTime(2026, 10, 9, 23, 59, 59, 999);
      final after = DateTime(2026, 10, 10);
      expect(
        needsDaySeparator(
          previousClockMs: before.millisecondsSinceEpoch,
          clockMs: after.millisecondsSinceEpoch,
        ),
        isTrue,
      );
    });

    test('the label follows a fake clock across midnight', () {
      final morning = DateTime(2026, 10, 9, 8);
      // The clock stands one millisecond before midnight.
      var now = DateTime(2026, 10, 9, 23, 59, 59, 999);
      expect(chatDayLabel(day: morning, now: now), ChatDayLabel.today);
      expect(
        chatDayLabel(day: DateTime(2026, 10, 9, 23, 59), now: now),
        ChatDayLabel.today,
      );

      // One millisecond later it is the next day.
      now = DateTime(2026, 10, 10);
      expect(chatDayLabel(day: morning, now: now), ChatDayLabel.yesterday);
      expect(
        chatDayLabel(day: DateTime(2026, 10, 10, 0, 0, 1), now: now),
        ChatDayLabel.today,
      );
      expect(
        chatDayLabel(day: DateTime(2026, 10, 8, 23, 59), now: now),
        ChatDayLabel.other,
      );
    });

    test('a day two days back is named by its date, not as yesterday', () {
      expect(
        chatDayLabel(day: DateTime(2026, 10, 7), now: DateTime(2026, 10, 9)),
        ChatDayLabel.other,
      );
    });

    test('a daylight-saving change does not move a message to another day', () {
      // The days either side of a spring clock change, whatever the zone.
      expect(
        chatDayLabel(
          day: DateTime(2026, 3, 28, 23, 30),
          now: DateTime(2026, 3, 29, 0, 30),
        ),
        ChatDayLabel.yesterday,
      );
    });

    test('an outgoing message is timed by when it was sent', () {
      final message = _message(
        'sent',
        outgoing: true,
        state: ChatState.delivered,
        ts: 1000,
        arrivedAt: 5000,
      );
      expect(message.clockMs, 1000);
    });

    test('an incoming message is timed by when it arrived on this device', () {
      final message = _message(
        'got',
        outgoing: false,
        state: ChatState.received,
        ts: 1000,
        arrivedAt: 5000,
      );
      expect(message.clockMs, 5000);
    });

    test('an incoming message with no arrival time is timed by ts', () {
      final message = _message(
        'legacy',
        outgoing: false,
        state: ChatState.received,
        ts: 1000,
      );
      expect(message.arrivedAt, isNull);
      expect(message.clockMs, 1000);
    });
  });

  group('the chat screen', () {
    late ChatStore store;
    late ChatManager chat;

    setUp(() {
      store = ChatStore(MemorySecretStore());
      chat = _chatWith(store: store);
    });

    tearDown(() async {
      await chat.dispose();
    });

    testWidgets('the verified badge shows only for a verified contact', (
      tester,
    ) async {
      await _pump(tester, chat);
      expect(find.byIcon(Icons.verified), findsNothing);

      await _pump(tester, chat, verified: true);
      expect(find.byIcon(Icons.verified), findsOneWidget);
      expect(
        find.byTooltip('You confirmed this safety number'),
        findsOneWidget,
      );
      await _unmount(tester, chat);
    });

    testWidgets('the header has no connection line', (tester) async {
      await _pump(tester, chat, verified: true);
      expect(find.text('Active now · E2EE'), findsNothing);
      expect(find.textContaining('E2EE'), findsNothing);
      await _unmount(tester, chat);
    });

    testWidgets('the composer shows a microphone until there is text', (
      tester,
    ) async {
      await _pump(tester, chat);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.send), findsNothing);

      await tester.enterText(find.byType(TextField), 'Salaam');
      await tester.pump();
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(find.byIcon(Icons.mic), findsOneWidget);
      await _unmount(tester, chat);
    });

    testWidgets('the microphone is the voice message button', (tester) async {
      // Recording needs a device, so the test only reads the button.
      await _pump(tester, chat);
      expect(find.byTooltip('Voice message'), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      await _unmount(tester, chat);
    });

    testWidgets('the footer says messages go directly, and nothing more', (
      tester,
    ) async {
      await _pump(tester, chat);
      expect(
        find.text(
          'Messages go directly between your devices while you are both online.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Nothing is stored'), findsNothing);
      await _unmount(tester, chat);
    });

    testWidgets('a delivered message shows one tick, a read one two', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.add(
          _message('one', outgoing: true, state: ChatState.delivered),
        );
        await store.add(_message('two', outgoing: true, state: ChatState.read));
      });
      await _pump(tester, chat);
      expect(find.byIcon(Icons.done), findsOneWidget);
      expect(find.byIcon(Icons.done_all), findsOneWidget);
      expect(find.text('Delivered'), findsOneWidget);
      expect(find.text('Read'), findsOneWidget);
      await _unmount(tester, chat);
    });

    testWidgets('a queued message can be cancelled from the queue', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.add(
          _message('later', outgoing: true, state: ChatState.queued),
        );
      });
      await _pump(tester, chat);
      expect(find.text('Queued'), findsOneWidget);
      expect(find.text('Cancel queue'), findsOneWidget);
      await _unmount(tester, chat);
    });

    testWidgets('an unanswered message says so by name, with Retry and Queue', (
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
      });
      await _pump(tester, chat);
      expect(find.text('Not sent: Bob did not answer.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Queue'), findsOneWidget);
      await _unmount(tester, chat);
    });

    testWidgets('the time of an incoming message is when it arrived here', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.add(
          _message(
            'hello',
            outgoing: false,
            state: ChatState.received,
            ts: _ms(2026, 10, 9, 9, 1),
            arrivedAt: _ms(2026, 10, 9, 15, 7),
          ),
        );
      });
      await _pump(tester, chat);
      final localizations = MaterialLocalizations.of(
        tester.element(find.byType(ChatPage)),
      );
      final arrived = localizations.formatTimeOfDay(
        const TimeOfDay(hour: 15, minute: 7),
      );
      final sent = localizations.formatTimeOfDay(
        const TimeOfDay(hour: 9, minute: 1),
      );
      expect(find.text(arrived), findsOneWidget);
      expect(find.text(sent), findsNothing);
      await _unmount(tester, chat);
    });

    testWidgets('a legacy incoming message with no arrival time shows its ts', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.add(
          _message(
            'old',
            outgoing: false,
            state: ChatState.received,
            ts: _ms(2026, 10, 9, 9, 1),
          ),
        );
      });
      await _pump(tester, chat);
      final localizations = MaterialLocalizations.of(
        tester.element(find.byType(ChatPage)),
      );
      expect(
        find.text(
          localizations.formatTimeOfDay(const TimeOfDay(hour: 9, minute: 1)),
        ),
        findsOneWidget,
      );
      await _unmount(tester, chat);
    });

    testWidgets('a day with messages in it is named once, Today or Yesterday', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.add(
          _message(
            'last night',
            outgoing: true,
            state: ChatState.delivered,
            ts: _ms(2026, 10, 8, 20),
          ),
        );
        await store.add(
          _message(
            'this morning',
            outgoing: false,
            state: ChatState.received,
            ts: _ms(2026, 10, 9, 9),
            arrivedAt: _ms(2026, 10, 9, 9),
          ),
        );
      });
      await _pump(tester, chat);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      await _unmount(tester, chat);
    });

    testWidgets('the day label changes at midnight with the injected clock', (
      tester,
    ) async {
      var now = DateTime(2026, 10, 9, 23, 59, 59, 999);
      final clockChat = _chatWith(clock: () => now);
      await tester.runAsync(
        () => clockChat.store.add(
          _message(
            'evening',
            outgoing: true,
            state: ChatState.delivered,
            ts: _ms(2026, 10, 9, 22),
          ),
        ),
      );
      await _pump(tester, clockChat);
      expect(find.text('Today'), findsOneWidget);

      now = DateTime(2026, 10, 10);
      await _pump(tester, clockChat);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsNothing);
      await _unmount(tester, clockChat);
    });

    testWidgets('the disappearing-messages pill names the time in words', (
      tester,
    ) async {
      await tester.runAsync(
        () => store.setRetention('bob', const Duration(hours: 24)),
      );
      expect(
        await tester.runAsync(() => store.retention('bob')),
        const Duration(hours: 24),
        reason: 'the setting is stored',
      );
      await _pump(tester, chat);
      // The page reads the setting after it opens: let that finish, then draw.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      final shown = [
        for (final e in find.byType(Text).evaluate())
          (e.widget as Text).data ?? '',
      ];
      expect(
        shown,
        contains('Disappearing messages: 24 hours timer active'),
        reason: 'texts on screen: $shown',
      );
      // The pill is a button: its whole area is at least 48 tall.
      final pill = find.ancestor(
        of: find.textContaining('Disappearing messages'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(pill.first).height, greaterThanOrEqualTo(48));
      await _unmount(tester, chat);
    });

    testWidgets(
      'a completed file you sent has no caption and reads Delivered',
      (tester) async {
        await tester.runAsync(() async {
          await store.add(_file(outgoing: true, status: 'completed'));
        });
        await _pump(tester, chat);
        expect(find.text('report.pdf'), findsOneWidget);
        expect(find.text('2.0 KB'), findsOneWidget);
        expect(find.text('Delivered'), findsOneWidget);
        expect(find.text('Sent file'), findsNothing);
        expect(find.textContaining('Decrypted'), findsNothing);
        await _unmount(tester, chat);
      },
    );

    testWidgets(
      'a file you have not yet been able to send says nothing of delivery',
      (tester) async {
        await tester.runAsync(() async {
          await store.add(_file(outgoing: true, status: 'transferring'));
        });
        await _pump(tester, chat);
        expect(find.text('Delivered'), findsNothing);
        expect(find.text('Sending'), findsOneWidget);
        await _unmount(tester, chat);
      },
    );

    testWidgets(
      'a completed file you received offers Open and Save to, and no caption',
      (tester) async {
        await tester.runAsync(() async {
          await store.add(
            _file(outgoing: false, status: 'completed', filePath: null),
          );
        });
        await _pump(tester, chat);
        expect(find.text('Open'), findsOneWidget);
        expect(find.text('Save to…'), findsOneWidget);
        expect(find.text('Received file'), findsNothing);
        await _unmount(tester, chat);
      },
    );

    testWidgets('an offered file you received has Accept and Decline', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.add(_file(outgoing: false, status: 'offered'));
      });
      await _pump(tester, chat);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
      await _unmount(tester, chat);
    });

    testWidgets('every button is at least 48 by 48', (tester) async {
      await tester.runAsync(() async {
        await store.setRetention('bob', const Duration(hours: 24));
        await store.add(
          _message('Lost', outgoing: true, state: ChatState.notSent),
        );
        await store.add(
          _message('Waiting', outgoing: true, state: ChatState.queued),
        );
        await store.add(_file(outgoing: false, status: 'offered'));
        await store.add(
          _file(outgoing: false, status: 'completed', filePath: 'a.pdf'),
        );
      });
      await _pump(tester, chat);

      final buttons = find.byWidgetPredicate(
        (widget) =>
            widget is TextButton ||
            widget is FilledButton ||
            widget is IconButton,
      );
      expect(buttons, findsWidgets);
      for (var i = 0; i < buttons.evaluate().length; i++) {
        final size = tester.getSize(buttons.at(i));
        expect(size.width, greaterThanOrEqualTo(48), reason: 'button $i width');
        expect(
          size.height,
          greaterThanOrEqualTo(48),
          reason: 'button $i height',
        );
      }
      await _unmount(tester, chat);
    });

    for (final (label, locale) in [
      ('Arabic', const Locale('ar')),
      ('Bengali', const Locale('bn')),
    ]) {
      testWidgets('$label at text scale 1.3 lays out with no overflow', (
        tester,
      ) async {
        await tester.runAsync(() async {
          await store.add(
            _message(
              'A long message that wraps over several lines in a narrow bubble',
              outgoing: true,
              state: ChatState.notSent,
              reason: 'no-answer',
            ),
          );
          await store.add(_file(outgoing: false, status: 'offered'));
        });
        await _pump(
          tester,
          chat,
          name: 'মোহাম্মদ আব্দুর রহমান আল-হাশিমি',
          locale: locale,
          textScale: 1.3,
        );
        expect(tester.takeException(), isNull);
        await _unmount(tester, chat);
      });
    }

    testWidgets('English in a right-to-left layout at text scale 1.3 fits', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.add(
          _message(
            'Right to left, with a link https://example.org/a/long/path',
            outgoing: false,
            state: ChatState.received,
          ),
        );
        await store.add(_file(outgoing: true, status: 'completed'));
      });
      await _pump(tester, chat, textScale: 1.3, direction: TextDirection.rtl);
      expect(tester.takeException(), isNull);
      await _unmount(tester, chat);
    });

    testWidgets(
      'with Hide my IP on, the footer and empty hint say messages are relayed',
      (tester) async {
        final relayChat = _chatWith(hideIp: () => true);
        await _pump(tester, relayChat);

        expect(
          find.text(
            'Hide my IP is on, so messages go through the Sotto server instead '
            'of directly between your devices.',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            'No messages yet. Hide my IP is on, so messages go through the Sotto '
            'server.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('go directly'), findsNothing);
        await _unmount(tester, relayChat);
      },
    );

    for (final (label, locale) in [
      ('English', const Locale('en')),
      ('Arabic', const Locale('ar')),
      ('Bengali', const Locale('bn')),
    ]) {
      testWidgets(
        'an empty chat fits 320 by 568 at text scale 1.3, in $label',
        (tester) async {
          _setScreen(tester, 320, 568);
          await _pump(tester, chat, locale: locale, textScale: 1.3);
          expect(tester.takeException(), isNull);
          await _unmount(tester, chat);
        },
      );
    }

    for (final width in [280.0, 300.0, 320.0]) {
      testWidgets('a completed voice note fits a $width dp phone', (
        tester,
      ) async {
        _setScreen(tester, width, 640);
        await tester.runAsync(() async {
          final note = _audio(
            outgoing: false,
            name: 'voice-1.wav',
            mime: 'audio/wav',
            voiceNote: true,
          );
          await store.add(note);
          store.rememberVoice(note.id, Uint8List(44));
        });
        await _pump(tester, chat);
        expect(tester.takeException(), isNull);
        await _unmount(tester, chat);
      });
    }

    testWidgets(
      'an offered voice note is a voice message, an audio file its name',
      (tester) async {
        await tester.runAsync(
          () => store.add(
            _audio(
              outgoing: false,
              name: 'voice-1.m4a',
              mime: 'audio/mp4',
              voiceNote: true,
              status: 'offered',
            ),
          ),
        );
        await _pump(tester, chat);
        expect(find.text('Voice message'), findsOneWidget);
        expect(find.text('voice-1.m4a'), findsNothing);
        await _unmount(tester, chat);
      },
    );

    testWidgets(
      'an offered audio file that is not a voice note keeps its name',
      (tester) async {
        await tester.runAsync(
          () => store.add(
            _audio(
              outgoing: false,
              name: 'holiday-song.m4a',
              mime: 'audio/mp4',
              voiceNote: false,
              status: 'offered',
            ),
          ),
        );
        await _pump(tester, chat);
        expect(find.text('holiday-song.m4a'), findsOneWidget);
        expect(find.text('Voice message'), findsNothing);
        await _unmount(tester, chat);
      },
    );

    testWidgets(
      'a chat left open past midnight names the new day without a rebuild',
      (tester) async {
        var now = DateTime(2026, 10, 9, 23, 59, 59, 999);
        final clockChat = _chatWith(clock: () => now);
        await tester.runAsync(
          () => clockChat.store.add(
            _message(
              'evening',
              outgoing: true,
              state: ChatState.delivered,
              ts: _ms(2026, 10, 9, 22),
            ),
          ),
        );
        await _pump(tester, clockChat);
        expect(find.text('Today'), findsOneWidget);

        // The clock passes midnight, and nothing else on the page changes.
        now = DateTime(2026, 10, 10, 0, 0, 1);
        await tester.pump(const Duration(minutes: 5));

        expect(find.text('Yesterday'), findsOneWidget);
        expect(find.text('Today'), findsNothing);
        await _unmount(tester, clockChat);
      },
    );

    testWidgets('resuming the app after midnight names the new day', (
      tester,
    ) async {
      var now = DateTime(2026, 10, 9, 23, 59);
      final clockChat = _chatWith(clock: () => now);
      await tester.runAsync(
        () => clockChat.store.add(
          _message(
            'evening',
            outgoing: true,
            state: ChatState.delivered,
            ts: _ms(2026, 10, 9, 22),
          ),
        ),
      );
      await _pump(tester, clockChat);
      expect(find.text('Today'), findsOneWidget);

      // The app was away past midnight, so no timer ran.
      now = DateTime(2026, 10, 10, 0, 30);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsNothing);
      await _unmount(tester, clockChat);
    });

    testWidgets('each day chip sits above the first message of its day', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.add(
          _message(
            'last night',
            outgoing: true,
            state: ChatState.delivered,
            ts: _ms(2026, 10, 8, 22),
          ),
        );
        await store.add(
          _message(
            'early',
            outgoing: true,
            state: ChatState.delivered,
            ts: _ms(2026, 10, 9, 6),
          ),
        );
        await store.add(
          _message(
            'this morning',
            outgoing: true,
            state: ChatState.delivered,
            ts: _ms(2026, 10, 9, 9),
          ),
        );
      });
      await _pump(tester, chat);

      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(top('Yesterday'), lessThan(top('last night')));
      expect(top('last night'), lessThan(top('Today')));
      expect(top('Today'), lessThan(top('early')));
      expect(top('early'), lessThan(top('this morning')));
      await _unmount(tester, chat);
    });

    testWidgets('a search keeps a chip above each day it shows', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await store.add(
          _message(
            'alpha',
            outgoing: true,
            state: ChatState.delivered,
            ts: _ms(2026, 10, 8, 9),
          ),
        );
        await store.add(
          _message(
            'beta',
            outgoing: true,
            state: ChatState.delivered,
            ts: _ms(2026, 10, 9, 9),
          ),
        );
        await store.add(
          _message(
            'alpha again',
            outgoing: true,
            state: ChatState.delivered,
            ts: _ms(2026, 10, 9, 20),
          ),
        );
      });
      await _pump(tester, chat);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();
      await tester.enterText(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(TextField),
        ),
        'alpha',
      );
      await tester.pump();

      // The middle message is filtered out; the two days still have chips.
      expect(find.text('beta'), findsNothing);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      await _unmount(tester, chat);
    });

    testWidgets(
      'an older page that loads adds its day chip in the right place',
      (tester) async {
        _setScreen(tester, 360, 1200);
        await tester.runAsync(() async {
          // Ten messages on the day before, then fifty on today: the first page
          // shows only today.
          for (var i = 0; i < 60; i++) {
            await store.add(
              _message(
                'message $i',
                outgoing: true,
                state: ChatState.delivered,
                ts: i < 10
                    ? _ms(2026, 10, 8, 9, i)
                    : _ms(2026, 10, 9, 9, i - 10),
              ),
            );
          }
        });
        await _pump(tester, chat);
        expect(find.text('Yesterday'), findsNothing);

        // Scroll up to the oldest end, which loads the next page. The list is
        // reversed, so older messages are above, and a drag down reveals them.
        await tester.drag(find.byType(ListView), const Offset(0, 4000));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();

        // Now at the oldest end of the whole chat: both day chips are on screen,
        // each above the first message of its day.
        await tester.drag(find.byType(ListView), const Offset(0, 4000));
        await tester.pump();
        expect(find.text('Yesterday'), findsOneWidget);
        expect(find.text('Today'), findsOneWidget);
        await _unmount(tester, chat);
      },
    );
  });

  group('the golden matrix', () {
    // One picture per light or dark, direction, language and text scale. Each
    // picture holds every state in section 11 of the spec.
    List<ChatMessage> allStates() => [
      _message(
        'Salaam, how are you?',
        outgoing: false,
        state: ChatState.received,
        ts: _ms(2026, 10, 8, 20),
      ),
      _message(
        'Sending now',
        outgoing: true,
        state: ChatState.sending,
        ts: _ms(2026, 10, 9, 9),
      ),
      _message(
        'Queued for later',
        outgoing: true,
        state: ChatState.queued,
        ts: _ms(2026, 10, 9, 9, 1),
      ),
      _message(
        'Delivered',
        outgoing: true,
        state: ChatState.delivered,
        ts: _ms(2026, 10, 9, 9, 2),
      ),
      _message(
        'Read',
        outgoing: true,
        state: ChatState.read,
        ts: _ms(2026, 10, 9, 9, 3),
      ),
      _message(
        'Not sent',
        outgoing: true,
        state: ChatState.notSent,
        reason: 'no-answer',
        ts: _ms(2026, 10, 9, 9, 4),
      ),
      _file(outgoing: false, status: 'offered'),
      _file(outgoing: true, status: 'completed'),
      _file(outgoing: false, status: 'completed', filePath: 'web:report'),
      _audio(
        outgoing: false,
        name: 'voice-1.wav',
        mime: 'audio/wav',
        voiceNote: true,
      ),
    ];

    for (final dark in [false, true]) {
      for (final rtl in [false, true]) {
        for (final (code, locale) in [
          ('en', const Locale('en')),
          ('ar', const Locale('ar')),
          ('bn', const Locale('bn')),
        ]) {
          for (final scale in [1.0, 1.3]) {
            final name =
                '${dark ? 'dark' : 'light'}_${rtl ? 'rtl' : 'ltr'}_${code}_'
                '${scale == 1.0 ? '1.0' : '1.3'}';
            testWidgets('the chat, $name', (tester) async {
              _setScreen(tester, 360, 1300);
              final goldenChat = _chatWith();
              await tester.runAsync(() async {
                for (final message in allStates()) {
                  await goldenChat.store.add(message);
                  if (message.voiceNote) {
                    goldenChat.store.rememberVoice(message.id, Uint8List(44));
                  }
                }
              });
              await _pump(
                tester,
                goldenChat,
                name: code == 'bn' ? 'মোহাম্মদ আব্দুর রহমান আল-হাশিমি' : 'Bob',
                locale: locale,
                textScale: scale,
                direction: rtl ? TextDirection.rtl : null,
                dark: dark,
              );
              expect(tester.takeException(), isNull);
              await expectLater(
                find.byType(ChatPage),
                matchesGoldenFile('goldens/chat_$name.png'),
              );
              await _unmount(tester, goldenChat);
            });
          }
        }
      }
    }
  });

  test(
    'chat_page.dart carries no green, cyan or amber, and no unbacked claim',
    () {
      final source = File('lib/chat/ui/chat_page.dart').readAsStringSync();
      for (final banned in [
        '10B981',
        '38BDF8',
        'F59E0B',
        'E2EE',
        'Active now',
        'Decrypted in RAM',
        // The strings that were hard-coded in English, now from the ARB files.
        'Could not open file',
        'Could not save file',
        // The exception text is not shown in a SnackBar.
        "Text('\$e')",
        'timer active',
        'did not answer',
        'Nothing is stored',
        'You confirmed this safety number',
      ]) {
        expect(
          source.contains(banned),
          isFalse,
          reason: '"$banned" must not appear in chat_page.dart',
        );
      }
    },
  );
}
