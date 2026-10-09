import 'dart:async';
import 'dart:io';

// The platform interface is a transitive package, the one audioplayers uses.
// ignore: depend_on_referenced_packages
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/chat/file_storage.dart';
import 'package:sotto/chat/voice/voice_format.dart';
import 'package:sotto/chat/voice/voice_player.dart';
import 'package:sotto/chat/voice/voice_recorder.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

import 'fake_record.dart';

/// A stand-in for the audioplayers platform. It plays nothing. It records the
/// players created, the players resumed, and sends the prepared event when a
/// source is set. [complete] sends the event for a player reaching its end.
class _FakeAudioplayers extends AudioplayersPlatformInterface {
  /// The player ids, in the order they were created.
  final created = <String>[];

  /// The player ids that were told to resume (that is, to play).
  final resumed = <String>[];

  final _events = <String, StreamController<AudioEvent>>{};

  StreamController<AudioEvent> _controller(String playerId) => _events
      .putIfAbsent(playerId, () => StreamController<AudioEvent>.broadcast());

  void complete(String playerId) =>
      _controller(playerId)
          .add(const AudioEvent(eventType: AudioEventType.complete));

  @override
  Future<void> create(String playerId) async {
    created.add(playerId);
  }

  @override
  Future<void> dispose(String playerId) async {}

  @override
  Future<void> stop(String playerId) async {}

  @override
  Future<void> pause(String playerId) async {}

  @override
  Future<void> resume(String playerId) async {
    resumed.add(playerId);
  }

  @override
  Future<void> setSourceUrl(
    String playerId,
    String url, {
    bool? isLocal,
    String? mimeType,
  }) async {
    scheduleMicrotask(
      () => _controller(playerId).add(
        const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true),
      ),
    );
  }

  @override
  Stream<AudioEvent> getEventStream(String playerId) =>
      _controller(playerId).stream;

  @override
  Future<int?> getDuration(String playerId) async => null;

  @override
  Future<int?> getCurrentPosition(String playerId) async => null;

  // Everything else is not used by the player, and does nothing.
  @override
  Object? noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _FakeGlobalAudioplayers implements GlobalAudioplayersPlatformInterface {
  @override
  Future<void> init() async {}

  @override
  Future<void> setGlobalAudioContext(AudioContext ctx) async {}

  @override
  Future<void> emitGlobalLog(String message) async {}

  @override
  Future<void> emitGlobalError(String code, String message) async {}

  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => const Stream.empty();
}

/// A store whose next copy write waits for [gate], so a test can act while a
/// start is still writing its copy.
class _GatedStore extends ReceivedFileStore {
  _GatedStore({required super.sodium, required super.directory});

  Completer<void>? gate;

  @override
  Future<File> writeOpenCopy(String fileName, Uint8List bytes) async {
    final wait = gate;
    gate = null;
    if (wait != null) await wait.future;
    return super.writeOpenCopy(fileName, bytes);
  }
}

/// Lets the queued platform events and futures run.
Future<void> _pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Sodium sodium;
  late Directory root;
  late Directory received;
  late ReceivedFileStore files;
  late FakeRecord record;

  setUpAll(() async {
    sodium = await SottoCrypto.init();
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('sotto_voice_');
    received = Directory('${root.path}/received');
    files = ReceivedFileStore(sodium: sodium, directory: () async => received);
    // The temporary folder the recorder and the player write into.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async =>
              call.method == 'getTemporaryDirectory' ? root.path : null,
        );
    record = FakeRecord();
    RecordPlatform.instance = record;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    root.deleteSync(recursive: true);
  });

  VoiceRecorder recorder() => VoiceRecorder(files: files, onLimit: () {});

  group('starting', () {
    test(
      'a refused microphone is a permission failure, and nothing starts',
      () async {
        record.permission = false;
        final voice = recorder();

        await expectLater(
          voice.start(),
          throwsA(
            isA<VoiceRecordException>().having(
              (e) => e.failure,
              'failure',
              VoiceFailure.permission,
            ),
          ),
        );
        expect(record.calls, isNot(contains('start')));
        await voice.dispose();
      },
    );

    test(
      'a cancel while the microphone prompt is open starts nothing',
      () async {
        record.permissionPrompt = Completer<bool>();
        final voice = recorder();

        final starting = voice.start();
        await voice.cancel();
        record.permissionPrompt!.complete(true);
        await starting;

        expect(voice.isRecording, isFalse);
        expect(record.calls, isNot(contains('start')));
        expect(record.calls, isNot(contains('startStream')));
        await voice.dispose();
      },
    );

    test(
      'a dispose while the microphone prompt is open starts nothing',
      () async {
        record.permissionPrompt = Completer<bool>();
        final voice = recorder();

        final starting = voice.start();
        final disposed = voice.dispose();
        record.permissionPrompt!.complete(true);
        await starting;
        await disposed;

        expect(voice.isRecording, isFalse);
        expect(record.calls, isNot(contains('start')));
        expect(record.calls, isNot(contains('startStream')));
      },
    );

    test(
      'on Windows, a start error is not blamed on the privacy setting',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        record.startError = PlatformException(
          code: 'no-device',
          message: 'no input device',
        );
        final voice = recorder();

        await expectLater(
          voice.start(),
          throwsA(
            isA<VoiceRecordException>().having(
              (e) => e.failure,
              'failure',
              VoiceFailure.unavailable,
            ),
          ),
        );
        await voice.dispose();
      },
    );

    test('a stream recording that runs past the limit is cut to it, and is not refused', () async {
      // The stream route, which is the Linux route. The limit timer fires at
      // 300 s, and audio keeps arriving until the stop, so the capture is a
      // little longer than the limit.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final voice = recorder();
      await voice.start();
      // 300 s of 16 kHz mono 16-bit audio, and 100 ms more.
      record.pcm!.add(
        Uint8List.fromList(List.filled(maxVoiceSeconds * 32000 + 3200, 5)),
      );
      await Future<void>.delayed(Duration.zero);

      final note = await voice.stop();

      expect(note.mime, 'audio/wav');
      expect(note.bytes.length, 44 + maxVoiceSeconds * 32000);
      expect(
        voiceOfferRefused(mime: note.mime, size: note.bytes.length),
        isFalse,
      );
      await voice.dispose();
    });

    test('a platform that adjusts the capture to a format the receiver refuses records nothing', () async {
      // The stream route, which is the Linux route.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      record.adjusted = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 2,
      );
      final voice = VoiceRecorder(files: null, onLimit: () {});

      await expectLater(voice.start(), throwsA(isA<VoiceRecordException>()));
      expect(voice.isRecording, isFalse);
      expect(record.calls, contains('cancel'));
      await voice.dispose();
    });
  });

  group('stopping', () {
    test('a stop that returns no file leaves no recording behind', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      record.stopReturnsPath = false;
      final voice = recorder();
      await voice.start();
      final path = record.path!;

      await expectLater(voice.stop(), throwsA(isA<VoiceRecordException>()));

      expect(File(path).existsSync(), isFalse);
      expect(voice.isRecording, isFalse);
      await voice.dispose();
    });

    test('a stop that throws leaves no recording behind', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final voice = recorder();
      await voice.start();
      final path = record.path!;
      record.stopError = PlatformException(code: 'stop-failed');

      await expectLater(voice.stop(), throwsA(isA<VoiceRecordException>()));

      expect(File(path).existsSync(), isFalse);
      await voice.dispose();
    });

    test(
      'a recording that stops cleanly is read back, and its file deleted',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final voice = recorder();
        await voice.start();
        final path = record.path!;

        final note = await voice.stop();

        expect(note.mime, 'audio/mp4');
        expect(note.extension, 'm4a');
        expect(note.bytes.length, 1000);
        expect(File(path).existsSync(), isFalse);
        await voice.dispose();
      },
    );

    test(
      'on Windows, a silent recording is a microphone problem, and deleted',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        record.level = -160;
        final voice = recorder();
        await voice.start();
        final path = record.path!;

        await expectLater(
          voice.stop(),
          throwsA(
            isA<VoiceRecordException>().having(
              (e) => e.failure,
              'failure',
              VoiceFailure.micPrivacy,
            ),
          ),
        );
        expect(File(path).existsSync(), isFalse);
        await voice.dispose();
      },
    );

    test(
      'on Windows, a short recording with speech in it is not judged silent',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        record.level = -6;
        final voice = recorder();
        await voice.start();

        // Stopped before the first level poll: the level is read at the stop.
        final note = await voice.stop();

        expect(note.bytes.length, 1000);
        await voice.dispose();
      },
    );

    test('a stream recording is a WAV file of the audio it captured', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final voice = VoiceRecorder(files: null, onLimit: () {});
      await voice.start();
      record.pcm!.add(Uint8List.fromList(List.filled(3200, 5)));
      await Future<void>.delayed(Duration.zero);

      final note = await voice.stop();

      expect(note.mime, 'audio/wav');
      expect(note.extension, 'wav');
      expect(note.bytes.length, 44 + 3200);
      expect(voiceBytesLookRight('audio/wav', note.bytes), isTrue);
      await voice.dispose();
    });
  });

  group('playing', () {
    test('a player disposed before its note is read plays nothing and keeps no copy', () async {
      // The copy route, which iOS, macOS and Linux use.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final player = VoicePlayer(copies: files);
      await player.dispose();

      await player.start(
        Uint8List.fromList(List.filled(100, 1)),
        mime: 'audio/mp4',
        name: 'voice-1.m4a',
      );

      expect(Directory('${root.path}/received_open').existsSync(), isFalse);
    });

    group('with the copy route', () {
      late _FakeAudioplayers fake;
      final note = Uint8List.fromList(List.filled(100, 1));

      /// The copies still on disk in the temporary folder.
      List<File> copies() {
        final folder = Directory('${root.path}/received_open');
        if (!folder.existsSync()) return [];
        return folder.listSync(recursive: true).whereType<File>().toList();
      }

      setUp(() {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        fake = _FakeAudioplayers();
        AudioplayersPlatformInterface.instance = fake;
        GlobalAudioplayersPlatformInterface.instance =
            _FakeGlobalAudioplayers();
      });

      test('stopping playback removes the copy', () async {
        final player = VoicePlayer(copies: files);
        await player.start(note, mime: 'audio/mp4', name: 'voice-1.m4a');
        await _pump();
        expect(copies(), hasLength(1));
        expect(fake.resumed, hasLength(1));

        await player.stop();
        await _pump();

        expect(copies(), isEmpty);
        await player.dispose();
      });

      test('a note that plays to its end removes the copy', () async {
        final player = VoicePlayer(copies: files);
        await player.start(note, mime: 'audio/mp4', name: 'voice-1.m4a');
        await _pump();
        expect(copies(), hasLength(1));

        fake.complete(fake.created.single);
        await _pump();

        expect(copies(), isEmpty);
        await player.dispose();
      });

      test(
        'a stop during the copy write stops the start: no playback, no copy',
        () async {
          final store = _GatedStore(
            sodium: sodium,
            directory: () async => received,
          );
          final player = VoicePlayer(copies: store);
          final gate = store.gate = Completer<void>();
          final starting = player.start(
            note,
            mime: 'audio/mp4',
            name: 'voice-1.m4a',
          );
          await _pump();

          await player.stop();
          gate.complete();
          await starting;
          await _pump();

          expect(fake.resumed, isEmpty);
          expect(copies(), isEmpty);
          await player.dispose();
        },
      );

      test('a second note started while the first copy is written: the first never plays', () async {
        final store = _GatedStore(
          sodium: sodium,
          directory: () async => received,
        );
        final first = VoicePlayer(copies: store);
        final second = VoicePlayer(copies: store);
        final gate = store.gate = Completer<void>();
        final starting = first.start(note, mime: 'audio/mp4', name: 'a.m4a');
        await _pump();

        await second.start(note, mime: 'audio/mp4', name: 'b.m4a');
        gate.complete();
        await starting;
        await _pump();

        expect(fake.created, hasLength(2));
        expect(fake.resumed, [fake.created[1]]);
        expect(copies(), hasLength(1));
        await first.dispose();
        await second.dispose();
      });
    });
  });
}
