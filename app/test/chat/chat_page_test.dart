import 'dart:io' show Directory, File, ZLibEncoder;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:sotto/call/call_controller.dart';
import 'package:sotto/call/call_manager.dart';
import 'package:sotto/call/screen_awake.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/file_storage.dart';
import 'package:sotto/chat/ui/chat_page.dart';
import 'package:sotto/chat/ui/chat_tokens.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/l10n/language.dart';
import 'package:sotto/core/theme.dart';
import 'package:sotto/crypto/identity_store.dart';
import 'package:sotto/chat/voice/voice_format.dart';

import 'fake_record.dart';

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

/// CRC-32 as PNG uses it, over [bytes].
int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

List<int> _chunk(String type, List<int> data) {
  final body = [...type.codeUnits, ...data];
  final crc = _crc32(body);
  return [..._u32(data.length), ...body, ..._u32(crc)];
}

List<int> _u32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

/// A PNG of [width] by [height] grey pixels. With [rows] false its pixel data
/// is a few bytes only, so a huge size costs nothing to send: the attack.
Uint8List _png(int width, int height, {bool rows = true}) {
  final raw = <int>[];
  if (rows) {
    for (var y = 0; y < height; y++) {
      raw.add(0); // no filter
      raw.addAll(List.filled(width, 0x80));
    }
  } else {
    raw.addAll([0, 0, 0, 0]);
  }
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
    ..._chunk('IHDR', [
      ..._u32(width),
      ..._u32(height),
      8, // bit depth
      0, // greyscale
      0,
      0,
      0,
    ]),
    ..._chunk('IDAT', ZLibEncoder().convert(raw)),
    ..._chunk('IEND', const []),
  ]);
}

/// A received image, complete, whose bytes the store holds in memory.
ChatMessage _image(String name) => ChatMessage(
  id: ChatFrames.newId(),
  contactId: 'bob',
  outgoing: false,
  ts: 1700000000000,
  text: name,
  state: ChatState.received,
  fileId: ChatFrames.newId(),
  fileName: name,
  fileSize: 100,
  fileMime: 'image/png',
  fileStatus: 'completed',
  filePath: 'web:$name',
);

/// A store whose decrypted copy for opening is a plain temp file, so the
/// Android open path runs without the encrypted file store.
class _CopyStore extends ChatStore {
  _CopyStore(this.copy) : super(MemorySecretStore());

  final File copy;

  @override
  Future<File> openCopy(ChatMessage message) async => copy;
}

class _NoScreenAwake implements ScreenAwake {
  @override
  Future<void> keepOn(bool on) async {}
}

/// A call controller whose call state the test sets.
class _CallsOf extends CallController {
  _CallsOf()
    : super(
        relayUrl: Uri.parse('ws://localhost:1/relay'),
        linkBase: Uri.parse('http://localhost:1/'),
        screenAwake: _NoScreenAwake(),
      );

  CallState state = CallState.idle;

  @override
  CallState get call => state;
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
    CallController? calls,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        locale: AppLanguage.english.locale,
        supportedLocales: AppLanguage.supported,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ChatPage(chat: chat, contactId: 'bob', name: name, calls: calls),
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
        'No messages yet. Messages are end-to-end encrypted and reach them even when their app is in the background.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('writing a message stores it and shows it as sending', (
    tester,
  ) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'Salaam');
    // The send button replaces the microphone once there is text.
    await tester.pump();
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
    expect(find.text('Not sent: Bob did not answer.'), findsOneWidget);
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
      find.text('Not sent: Muhammad Abdul Rahman Al-Hashimi did not answer.'),
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
        final tokens = theme.extension<ChatTokens>()!;

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
        expect(label, tokens.sentText);
        expect(
          background,
          tokens.sentFill,
          reason: 'the bubble is not the sent-message fill',
        );
        expect(_contrastRatio(label!, background!), greaterThanOrEqualTo(4.5));

        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('opening chat page marks unread messages as read', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await store.add(
        ChatMessage(
          id: ChatFrames.newId(),
          contactId: 'bob',
          outgoing: false,
          ts: 1700000000000,
          text: 'Unread message',
          state: ChatState.received,
          read: false,
        ),
      );
      expect(await store.unreadCount('bob'), 1);
    });

    await pumpPage(tester);

    await tester.runAsync(() async {
      expect(await store.unreadCount('bob'), 0);
    });
  });

  testWidgets('bubble long press displays action sheet and allows deletion', (
    tester,
  ) async {
    final msg = _message(
      'Message to delete',
      outgoing: true,
      state: ChatState.delivered,
    );
    await tester.runAsync(() => store.add(msg));

    await pumpPage(tester);
    expect(find.text('Message to delete'), findsOneWidget);

    // Long press on the bubble
    await tester.longPress(find.text('Message to delete'));
    await tester.pumpAndSettle();

    expect(find.text('Copy text'), findsOneWidget);
    expect(find.text('Delete message'), findsOneWidget);

    // Tap Delete message
    await tester.tap(find.text('Delete message'));
    await tester.pumpAndSettle();

    expect(find.text('Delete this message?'), findsOneWidget);

    // Confirm deletion
    await tester.tap(find.text('Delete'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Message to delete'), findsNothing);
    final remaining = await tester.runAsync(() => store.messages('bob'));
    expect(remaining, isEmpty);
  });

  test('a failed open or save shows its own text, never the exception', () {
    for (final locale in [const Locale('en'), const Locale('ar')]) {
      final l10n = lookupAppLocalizations(locale);
      expect(
        fileErrorMessage(
          l10n,
          StateError('/private/path: internal'),
          l10n.chatFileOpenFailed,
        ),
        l10n.chatFileOpenFailed,
        reason: '$locale',
      );
      expect(
        fileErrorMessage(
          l10n,
          const ReceivedFileException('missing'),
          l10n.chatFileSaveFailed,
        ),
        l10n.chatFileUnavailable,
        reason: '$locale',
      );
      expect(
        fileErrorMessage(
          l10n,
          const ReceivedFileException('damaged'),
          l10n.chatFileOpenFailed,
        ),
        l10n.chatFileUnreadable,
        reason: '$locale',
      );
    }
  });

  test('a refused file gives its error in the app language', () {
    for (final locale in [const Locale('en'), const Locale('ar')]) {
      final l10n = lookupAppLocalizations(locale);
      expect(
        offerErrorMessage(l10n, ArgumentError('Image could not be read')),
        l10n.chatImageUnreadable,
        reason: '$locale',
      );
      expect(
        offerErrorMessage(
          l10n,
          ArgumentError('Image type not supported for sharing'),
        ),
        l10n.chatImageUnsupported,
        reason: '$locale',
      );
      expect(
        offerErrorMessage(l10n, ArgumentError('File exceeds max size limit')),
        l10n.chatFileTooLarge,
        reason: '$locale',
      );
      expect(
        offerErrorMessage(l10n, ArgumentError('Blocked file type: setup.exe')),
        l10n.chatFileBlocked,
        reason: '$locale',
      );
    }
    // Any other error keeps its text, as before.
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(
      offerErrorMessage(l10n, StateError('Peer is offline')),
      'Bad state: Peer is offline',
    );
  });

  group('received images are checked before they are decoded', () {
    test('the size limits', () {
      expect(imageSizeAllowed(4000, 3000), isTrue);
      expect(imageSizeAllowed(maxImageSide, 4000), isTrue);
      expect(imageSizeAllowed(maxImageSide + 1, 10), isFalse);
      expect(imageSizeAllowed(10, maxImageSide + 1), isFalse);
      // 8000 x 6000 is 48 MP: each side is allowed, the pixel count is not.
      expect(imageSizeAllowed(8000, 6000), isFalse);
      expect(imageSizeAllowed(30000, 30000), isFalse);
      expect(imageSizeAllowed(0, 10), isFalse);
    });

    testWidgets('a small file that declares 30000 x 30000 is refused', (
      tester,
    ) async {
      final bomb = _png(30000, 30000, rows: false);
      expect(bomb.length, lessThan(200));
      final header = await tester.runAsync(() => imageHeaderSize(bomb));
      expect(header, (width: 30000, height: 30000));
      expect(await tester.runAsync(() => safeImageSize(bomb)), isNull);

      final ok = _png(4, 3);
      expect(await tester.runAsync(() => safeImageSize(ok)), (
        width: 4,
        height: 3,
      ));
      // Bytes that are not an image have no size.
      expect(
        await tester.runAsync(
          () => imageHeaderSize(Uint8List.fromList([1, 2, 3, 4])),
        ),
        isNull,
      );
    });

    Future<void> showImage(WidgetTester tester, Uint8List bytes) async {
      final message = _image('photo.png');
      await tester.runAsync(() => store.add(message));
      store.rememberFile(message.fileId!, bytes);
      await pumpPage(tester);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    testWidgets('the thumbnail of an image bomb is never decoded', (
      tester,
    ) async {
      await showImage(tester, _png(30000, 30000, rows: false));
      expect(find.text('Could not load image'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a thumbnail is decoded at the size it is shown', (
      tester,
    ) async {
      await showImage(tester, _png(40, 30));
      expect(find.text('Could not load image'), findsNothing);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<ResizeImage>());
      final resize = image.image as ResizeImage;
      // Never larger than the image itself.
      expect(resize.width, lessThanOrEqualTo(40));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('opening and saving a received file on Android', () {
    const channel = MethodChannel('sotto/android');
    late List<MethodCall> calls;

    ChatMessage pdf() => ChatMessage(
      id: ChatFrames.newId(),
      contactId: 'bob',
      outgoing: false,
      ts: 1700000000000,
      text: 'report.pdf',
      state: ChatState.received,
      fileId: ChatFrames.newId(),
      fileName: 'report.pdf',
      fileSize: 4,
      fileMime: 'application/pdf',
      fileStatus: 'completed',
      filePath: 'web:report.pdf',
    );

    /// Shows one received file on an Android page whose native side throws.
    Future<void> showOnAndroid(
      WidgetTester tester,
      ChatStore fileStore, {
      required String code,
    }) async {
      calls = [];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        throw PlatformException(code: code);
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final message = pdf();
      await tester.runAsync(() => fileStore.add(message));
      fileStore.rememberFile(message.fileId!, Uint8List.fromList([1, 2, 3, 4]));
      await chat.dispose();
      chat = ChatManager(
        myId: 'alice',
        store: fileStore,
        isContact: {'bob'}.contains,
        send: (to, type, body, callId) {},
        iceServers: () async => const [],
        hideIp: () => false,
        createRtc: ({required iceServers, required relayOnly}) async =>
            throw StateError('no connection in this test'),
        clock: DateTime.now,
      );
      await pumpPage(tester);
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    for (final (code, text) in [
      (
        'blocked_type',
        "This file type can't be opened here. Use Save instead.",
      ),
      ('no_app', 'No app on this device can open this file.'),
      ('failed', 'Could not open file'),
    ]) {
      testWidgets('an open refused with $code says so, and stops there', (
        tester,
      ) async {
        final dir = Directory.systemTemp.createTempSync('sotto_open');
        addTearDown(() => dir.deleteSync(recursive: true));
        final copy = File('${dir.path}/report.pdf')..writeAsBytesSync([1]);
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await showOnAndroid(tester, _CopyStore(copy), code: code);
          await tester.tap(find.text('Open'));
          await settle(tester);
          // One call, no fallback, and the peer's type is not passed on.
          expect(calls.single.method, 'openFile');
          expect(calls.single.arguments, {'path': copy.path});
          expect(find.text(text), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    for (final (code, text) in [
      ('failed', 'Could not save file'),
      ('permission_required', 'Allow storage access, then tap Save again.'),
    ]) {
      testWidgets('a save refused with $code writes nothing and says so', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await showOnAndroid(
            tester,
            ChatStore(MemorySecretStore()),
            code: code,
          );
          await tester.tap(find.text('Save to…'));
          await settle(tester);
          expect(calls.single.method, 'saveToDownloads');
          expect((calls.single.arguments as Map).containsKey('mime'), isFalse);
          expect(find.text(text), findsOneWidget);
          expect(find.textContaining('Saved to Downloads'), findsNothing);
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    test('open errors are translated in every language', () {
      for (final locale in AppLanguage.supported) {
        final l10n = lookupAppLocalizations(locale);
        expect(
          openFileErrorMessage(l10n, 'blocked_type'),
          l10n.chatFileTypeCannotOpen,
        );
        expect(openFileErrorMessage(l10n, 'no_app'), l10n.chatFileNoApp);
        expect(
          openFileErrorMessage(l10n, 'not_found'),
          l10n.chatFileOpenFailed,
        );
      }
    });
  });

  group('voice messages on the chat screen', () {
    late FakeRecord record;

    setUp(() {
      record = FakeRecord();
      RecordPlatform.instance = record;
    });

    /// A voice test on the stream route, which is the Linux route. It keeps
    /// the audio in memory, so the page needs no file store to record. The
    /// override is reset inside the test, since the framework checks it
    /// before tearDown runs.
    void voiceTest(
      String description,
      Future<void> Function(WidgetTester tester) body,
    ) {
      testWidgets(description, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    /// Taps the mic and lets the recorder start.
    Future<void> startRecording(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    /// Runs the recording to the 5-minute limit. The limit stops the capture,
    /// which finishes its file work in real time, so the test lets that run.
    Future<void> reachLimit(WidgetTester tester) async {
      record.pcm!.add(Uint8List.fromList(List.filled(3200, 5)));
      await tester.pump();
      await tester.pump(const Duration(seconds: maxVoiceSeconds));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    voiceTest('back while recording asks first, and Discard drops it', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: AppLanguage.english.locale,
          supportedLocales: AppLanguage.supported,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      ChatPage(chat: chat, contactId: 'bob', name: 'Bob'),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      await startRecording(tester);
      expect(find.byTooltip('Cancel recording'), findsOneWidget);

      // Back asks; Cancel keeps the recording and the screen.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard voice message?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(find.byTooltip('Cancel recording'), findsOneWidget);
      expect(record.calls, isNot(contains('cancel')));

      // Back again, and Discard: the recording is dropped and the page closes.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(record.calls, contains('cancel'));
      expect(find.byType(ChatPage), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(await store.messages('bob'), isEmpty);
    });

    voiceTest('leaving the screen discards a recording, and nothing is sent', (
      tester,
    ) async {
      await pumpPage(tester);
      await startRecording(tester);
      expect(find.byTooltip('Cancel recording'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(record.calls, contains('cancel'));

      // A paused app builds no frames, so the app comes back to see the screen.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byTooltip('Cancel recording'), findsNothing);
      expect(await store.messages('bob'), isEmpty);
    });

    voiceTest(
      'a call that starts discards a recording, and the mic stays off during the call',
      (tester) async {
        final calls = _CallsOf();
        addTearDown(calls.dispose);
        await pumpPage(tester, calls: calls);
        await startRecording(tester);
        expect(find.byTooltip('Cancel recording'), findsOneWidget);

        calls.state = const CallState(phase: CallPhase.incoming);
        calls.notifyListeners();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byTooltip('Cancel recording'), findsNothing);
        expect(record.calls, contains('cancel'));
        final mic = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.mic),
        );
        expect(mic.onPressed, isNull);
        expect(
          find.byTooltip('Voice messages are not available during a call.'),
          findsOneWidget,
        );
      },
    );

    voiceTest('the mic does not start while a call is active', (tester) async {
      final calls = _CallsOf()
        ..state = const CallState(phase: CallPhase.incoming);
      addTearDown(calls.dispose);
      await pumpPage(tester, calls: calls);

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(record.calls, isNot(contains('startStream')));
      expect(find.byTooltip('Cancel recording'), findsNothing);
    });

    voiceTest(
      'a recording that reaches the 5-minute limit stops, and waits to be sent or cancelled',
      (tester) async {
        await pumpPage(tester);
        await startRecording(tester);
        await reachLimit(tester);

        expect(record.calls, contains('stop'));
        expect(
          find.text(
            'Recording stopped at the 5-minute limit. Send it or cancel.',
          ),
          findsOneWidget,
        );
        expect(find.byTooltip('Send voice message'), findsOneWidget);
        expect(await store.messages('bob'), isEmpty);
      },
    );

    voiceTest(
      'cancelling a note held at the limit drops it, and nothing is sent',
      (tester) async {
        await pumpPage(tester);
        await startRecording(tester);
        await reachLimit(tester);

        await tester.tap(find.byTooltip('Cancel recording'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          find.text(
            'Recording stopped at the 5-minute limit. Send it or cancel.',
          ),
          findsNothing,
        );
        expect(find.byTooltip('Send voice message'), findsNothing);
        expect(await store.messages('bob'), isEmpty);
      },
    );
  });
}
