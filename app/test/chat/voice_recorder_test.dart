import 'dart:async';
import 'dart:io';

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

/// A stand-in for the platform recorder. It records no sound: a file route
/// writes a fixed block of bytes to the path it is given, and a stream route
/// hands out [pcm] for the test to fill.
class _FakeRecord extends RecordPlatform {
  /// The calls made, in order, by name.
  final calls = <String>[];

  bool permission = true;

  /// When set, the permission prompt stays open until this completes.
  Completer<bool>? permissionPrompt;

  /// Thrown by start, when set.
  Object? startError;

  /// Thrown by stop, when set.
  Object? stopError;

  /// Whether a file-route stop returns the path. False returns null.
  bool stopReturnsPath = true;

  /// The level every amplitude reading reports, in dB.
  double level = -160;

  /// The configuration the platform reports as adjusted, when set.
  RecordConfig? adjusted;

  /// The path of the last file-route recording.
  String? path;

  /// The stream of the last stream-route recording.
  StreamController<Uint8List>? pcm;

  void Function(RecordConfig config)? _onConfig;

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async {
    calls.add('hasPermission');
    final prompt = permissionPrompt;
    return prompt == null ? permission : prompt.future;
  }

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    calls.add('start');
    if (startError case final error?) throw error;
    this.path = path;
    await File(path).writeAsBytes(Uint8List.fromList(List.filled(1000, 9)));
  }

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    calls.add('startStream');
    if (startError case final error?) throw error;
    _onConfig?.call(adjusted ?? config);
    final controller = StreamController<Uint8List>();
    pcm = controller;
    return controller.stream;
  }

  @override
  Future<String?> stop(String recorderId) async {
    calls.add('stop');
    if (stopError case final error?) throw error;
    final stream = pcm;
    if (stream != null) {
      await stream.close();
      return null;
    }
    return stopReturnsPath ? path : null;
  }

  @override
  Future<void> cancel(String recorderId) async {
    calls.add('cancel');
    await pcm?.close();
  }

  @override
  Future<void> pause(String recorderId) async {}

  @override
  Future<void> resume(String recorderId) async {}

  @override
  Future<bool> isRecording(String recorderId) async => false;

  @override
  Future<bool> isPaused(String recorderId) async => false;

  @override
  Future<void> dispose(String recorderId) async {
    calls.add('dispose');
  }

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: level, max: level);

  @override
  Future<bool> isEncoderSupported(
    String recorderId,
    AudioEncoder encoder,
  ) async => true;

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async =>
      const [];

  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      const Stream<RecordState>.empty();

  @override
  void setOnConfigChanged(
    String recorderId,
    void Function(RecordConfig config)? handler,
  ) {
    _onConfig = handler;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Sodium sodium;
  late Directory root;
  late Directory received;
  late ReceivedFileStore files;
  late _FakeRecord record;

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
    record = _FakeRecord();
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
  });
}
