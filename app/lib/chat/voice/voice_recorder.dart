import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../file_storage.dart';
import 'voice_blob.dart';
import 'voice_format.dart';

/// Why a voice recording failed. The chat page says why, in words.
enum VoiceFailure { permission, micPrivacy, needsParecord, unavailable }

class VoiceRecordException implements Exception {
  const VoiceRecordException(this.failure);

  final VoiceFailure failure;

  @override
  String toString() => 'VoiceRecordException: ${failure.name}';
}

/// A finished recording, ready to offer.
class VoiceNote {
  const VoiceNote({
    required this.bytes,
    required this.mime,
    required this.extension,
  });

  final Uint8List bytes;

  /// `audio/mp4` or `audio/wav`.
  final String mime;

  /// `m4a` or `wav`.
  final String extension;
}

enum _Phase { idle, starting, recording, stopping }

/// Records one voice note at a time for the chat composer.
///
/// Most platforms record AAC-LC in MPEG-4 to a file in the temporary folder.
/// Linux records 16-bit PCM from parecord and wraps it in a WAV header, since
/// its file route needs ffmpeg. The browser records AAC-LC when the browser
/// can, and 16-bit PCM otherwise. A recording stops by itself at
/// [maxDuration] and calls [onLimit]; the caller then calls [stop].
///
/// Windows does not check the microphone permission, so a recording that
/// stays silent is refused by [stop] with [VoiceFailure.micPrivacy].
class VoiceRecorder {
  VoiceRecorder({
    required this.files,
    required this.onLimit,
    this.maxDuration = const Duration(seconds: maxVoiceSeconds),
  });

  /// Where native recordings are written. Null in the browser.
  final ReceivedFileStore? files;

  /// Called when the recording reaches [maxDuration].
  final void Function() onLimit;

  final Duration maxDuration;

  AudioRecorder? _recorder;
  _Phase _phase = _Phase.idle;
  final _clock = Stopwatch();
  Timer? _limitTimer;
  Timer? _meterTimer;
  double _peakDb = -160;

  /// Whether this recording uses the file route rather than the PCM stream.
  bool _fileRoute = true;

  /// The temporary file of a native recording, while it is being made.
  String? _path;

  StreamSubscription<Uint8List>? _pcmSub;
  Completer<void>? _pcmDone;
  bool _pcmFailed = false;
  IOSink? _pcmSink;
  List<Uint8List>? _pcmChunks;
  int _sampleRate = voiceSampleRate;
  int _channels = voiceChannels;

  /// The AAC-LC route: mono, 16 kHz, 32 kbps.
  static const _aacConfig = RecordConfig(
    encoder: AudioEncoder.aacLc,
    sampleRate: voiceSampleRate,
    numChannels: voiceChannels,
    bitRate: voiceAacBitRate,
  );

  /// The WAV fallback: 16-bit PCM, mono, 16 kHz.
  static const _pcmConfig = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: voiceSampleRate,
    numChannels: voiceChannels,
  );

  bool get isRecording => _phase == _Phase.recording;

  /// How long the current recording has run.
  Duration get elapsed => _clock.elapsed;

  static bool get _onWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Starts a recording. Throws [VoiceRecordException] when the microphone is
  /// not allowed or cannot be used.
  Future<void> start() async {
    if (_phase != _Phase.idle) return;
    final recorder = _recorder ??= AudioRecorder();
    final bool granted;
    try {
      granted = await recorder.hasPermission();
    } catch (_) {
      // The recorder itself is not available (no plugin, or it failed).
      throw const VoiceRecordException(VoiceFailure.unavailable);
    }
    if (!granted) {
      throw const VoiceRecordException(VoiceFailure.permission);
    }
    _phase = _Phase.starting;
    try {
      _fileRoute = kIsWeb
          ? await recorder.isEncoderSupported(AudioEncoder.aacLc)
          : defaultTargetPlatform != TargetPlatform.linux;
      if (_fileRoute) {
        final store = files;
        if (!kIsWeb && store == null) throw StateError('no file store');
        _path = kIsWeb ? null : (await store!.recordingFile('m4a')).path;
        await recorder.start(_aacConfig, path: _path ?? '');
      } else {
        await _startPcm(recorder);
      }
    } catch (error) {
      await _abandon();
      throw VoiceRecordException(_startFailure(error));
    }
    _phase = _Phase.recording;
    _clock
      ..reset()
      ..start();
    _limitTimer = Timer(maxDuration, () {
      if (_phase == _Phase.recording) onLimit();
    });
    if (_onWindows) {
      _meterTimer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => unawaited(_readPeak()),
      );
    }
  }

  /// Ends the recording and returns it. Throws [VoiceRecordException] when it
  /// cannot be read, or when it was silent (Windows).
  Future<VoiceNote> stop() async {
    if (_phase != _Phase.recording) {
      throw const VoiceRecordException(VoiceFailure.unavailable);
    }
    _phase = _Phase.stopping;
    _limitTimer?.cancel();
    _meterTimer?.cancel();
    _clock.stop();
    try {
      return _fileRoute ? await _stopFile() : await _stopPcm();
    } on VoiceRecordException {
      rethrow;
    } catch (_) {
      throw const VoiceRecordException(VoiceFailure.unavailable);
    } finally {
      _reset();
    }
  }

  /// Stops the recording and discards it. Nothing is returned.
  Future<void> cancel() async {
    if (_phase == _Phase.idle) return;
    await _abandon();
  }

  /// Cancels any recording and releases the recorder.
  Future<void> dispose() async {
    await cancel();
    await _recorder?.dispose();
    _recorder = null;
  }

  VoiceFailure _startFailure(Object error) {
    if (kIsWeb) return VoiceFailure.unavailable;
    if (defaultTargetPlatform == TargetPlatform.linux &&
        error is ProcessException) {
      // parecord is not installed (pulseaudio-utils).
      return VoiceFailure.needsParecord;
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return VoiceFailure.micPrivacy;
    }
    return VoiceFailure.unavailable;
  }

  Future<void> _startPcm(AudioRecorder recorder) async {
    var effective = _pcmConfig;
    // The plugin may adjust the format. The header must match what it records.
    await recorder.setOnConfigChanged((config) => effective = config);
    final stream = await recorder.startStream(_pcmConfig);
    await recorder.setOnConfigChanged(null);
    _sampleRate = effective.sampleRate;
    _channels = effective.numChannels;
    _pcmFailed = false;
    _pcmDone = Completer<void>();
    final store = files;
    if (store == null) {
      _pcmChunks = <Uint8List>[];
    } else {
      final file = await store.recordingFile('wav');
      _path = file.path;
      // The header is written again at the end, with the real length.
      _pcmSink = file.openWrite()
        ..add(
          wavHeader(
            sampleRate: _sampleRate,
            channels: _channels,
            bitsPerSample: voiceBitsPerSample,
            dataBytes: 0,
          ),
        );
    }
    _pcmSub = stream.listen(
      (chunk) {
        final sink = _pcmSink;
        if (sink != null) {
          sink.add(chunk);
        } else {
          _pcmChunks?.add(chunk);
        }
      },
      onError: (Object _) => _pcmFailed = true,
      onDone: () {
        final done = _pcmDone;
        if (done != null && !done.isCompleted) done.complete();
      },
    );
  }

  Future<VoiceNote> _stopFile() async {
    final out = await _recorder!.stop();
    if (out == null) {
      throw const VoiceRecordException(VoiceFailure.unavailable);
    }
    if (kIsWeb) {
      final VoiceBlob blob;
      try {
        blob = await readVoiceBlob(out);
      } finally {
        revokeVoiceBlob(out);
      }
      final mime = webRecordingMime(blob.type);
      if (!isVoiceMime(mime) || blob.bytes.isEmpty) {
        throw const VoiceRecordException(VoiceFailure.unavailable);
      }
      return VoiceNote(
        bytes: blob.bytes,
        mime: mime,
        extension: mime == 'audio/wav' ? 'wav' : 'm4a',
      );
    }
    final bytes = await _takeFile(File(out));
    if (_onWindows && isSilentPeak(_peakDb)) {
      throw const VoiceRecordException(VoiceFailure.micPrivacy);
    }
    return VoiceNote(bytes: bytes, mime: 'audio/mp4', extension: 'm4a');
  }

  Future<VoiceNote> _stopPcm() async {
    await _recorder!.stop();
    final done = _pcmDone;
    if (done != null) {
      // The stream closes when the capture ends. Waiting is bounded, so a
      // stream that never closes cannot hold the recording.
      await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    await _pcmSub?.cancel();
    _pcmSub = null;
    final sink = _pcmSink;
    _pcmSink = null;
    final Uint8List pcm;
    if (sink != null) {
      await sink.close();
      final file = File(_path!);
      final written = await _takeFile(file);
      pcm = written.length > 44 ? written.sublist(44) : Uint8List(0);
    } else {
      final builder = BytesBuilder(copy: false);
      for (final chunk in _pcmChunks ?? const <Uint8List>[]) {
        builder.add(chunk);
      }
      pcm = builder.takeBytes();
    }
    if (_pcmFailed) {
      throw const VoiceRecordException(VoiceFailure.unavailable);
    }
    // Whole 16-bit samples only.
    const blockAlign = voiceChannels * voiceBitsPerSample ~/ 8;
    final length = pcm.length - pcm.length % blockAlign;
    if (length == 0) {
      throw const VoiceRecordException(VoiceFailure.unavailable);
    }
    final header = wavHeader(
      sampleRate: _sampleRate,
      channels: _channels,
      bitsPerSample: voiceBitsPerSample,
      dataBytes: length,
    );
    final bytes = Uint8List(44 + length)
      ..setRange(0, 44, header)
      ..setRange(44, 44 + length, pcm);
    return VoiceNote(bytes: bytes, mime: 'audio/wav', extension: 'wav');
  }

  /// Reads a finished native recording and deletes it at once.
  Future<Uint8List> _takeFile(File file) async {
    try {
      return await file.readAsBytes();
    } finally {
      await files?.discardRecording(file);
    }
  }

  Future<void> _readPeak() async {
    try {
      final amp = await _recorder?.getAmplitude();
      if (amp != null && amp.current > _peakDb) _peakDb = amp.current;
    } catch (_) {}
  }

  /// Stops and discards whatever is recording, and removes its file.
  Future<void> _abandon() async {
    _limitTimer?.cancel();
    _meterTimer?.cancel();
    _clock.stop();
    try {
      await _recorder?.cancel();
    } catch (_) {}
    await _pcmSub?.cancel();
    try {
      await _pcmSink?.close();
    } catch (_) {}
    final path = _path;
    if (path != null) await files?.discardRecording(File(path));
    _reset();
  }

  void _reset() {
    _phase = _Phase.idle;
    _path = null;
    _pcmSub = null;
    _pcmDone = null;
    _pcmSink = null;
    _pcmChunks = null;
    _pcmFailed = false;
    _peakDb = -160;
    _clock.reset();
  }
}
