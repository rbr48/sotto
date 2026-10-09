import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';

/// A stand-in for the platform recorder, shared by the voice tests. It records
/// no sound: a file route writes a fixed block of bytes to the path it is
/// given, and a stream route hands out [pcm] for the test to fill.
class FakeRecord extends RecordPlatform {
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
