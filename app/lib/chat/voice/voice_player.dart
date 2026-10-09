import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../file_storage.dart';

/// What a [VoicePlayer] is doing: its state, and where it is in the note.
@immutable
class VoicePlayback {
  const VoicePlayback({
    this.state = PlayerState.stopped,
    this.position = Duration.zero,
    this.duration,
  });

  final PlayerState state;
  final Duration position;

  /// The length of the note, known once the player has loaded it.
  final Duration? duration;
}

/// Plays one voice note at a time, from decrypted bytes that stay in memory,
/// or from a copy in the temporary folder where the player needs a file.
///
/// Android, Windows and the browser play the bytes directly, with the MIME
/// type given. iOS, macOS and Linux play a copy made by
/// [ReceivedFileStore.writeOpenCopy]: audioplayers would write its own file
/// with a hash for a name, outside the store's sweep. The copy is removed
/// when playback stops, completes, or the player is disposed.
class VoicePlayer {
  VoicePlayer({this.copies});

  /// Writes the copies on iOS, macOS and Linux. Null in the browser.
  final ReceivedFileStore? copies;

  /// What the player is doing. The bubble listens to it.
  final playback = ValueNotifier<VoicePlayback>(const VoicePlayback());

  /// The player that is playing now. Starting another stops this one.
  static VoicePlayer? _playing;

  AudioPlayer? _player;
  File? _copy;
  final _subs = <StreamSubscription<dynamic>>[];

  static bool get _playsCopy =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// Plays [bytes] from the start, as [mime] (`audio/mp4` or `audio/wav`).
  /// [name] is the file name the copy is given, where a copy is needed.
  Future<void> start(
    Uint8List bytes, {
    required String mime,
    required String name,
  }) async {
    final other = _playing;
    if (other != null && other != this) await other.stop();
    _playing = this;
    final player = _ensurePlayer();
    await player.stop();
    await _removeCopy();
    final Source source;
    if (_playsCopy) {
      final store = copies;
      if (store == null) throw const ReceivedFileException('missing');
      _copy = await store.writeOpenCopy(name, bytes);
      source = DeviceFileSource(_copy!.path, mimeType: mime);
    } else {
      source = BytesSource(bytes, mimeType: mime);
    }
    try {
      await player.play(source);
    } catch (_) {
      await _removeCopy();
      rethrow;
    }
  }

  /// Pauses playback. The copy stays until playback stops or completes.
  Future<void> pause() async {
    await _player?.pause();
  }

  /// Carries on after [pause].
  Future<void> resume() async {
    await _player?.resume();
  }

  /// Stops playback and removes the copy.
  Future<void> stop() async {
    if (_playing == this) _playing = null;
    await _player?.stop();
    await _removeCopy();
    _update(state: PlayerState.stopped, position: Duration.zero);
  }

  /// Stops playback and releases the player. The player cannot be used after.
  Future<void> dispose() async {
    if (_playing == this) _playing = null;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _removeCopy();
    final player = _player;
    _player = null;
    await player?.dispose();
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer();
    _player = player;
    _subs
      ..add(
        player.onPlayerStateChanged.listen((state) => _update(state: state)),
      )
      ..add(
        player.onPositionChanged.listen(
          (position) => _update(position: position),
        ),
      )
      ..add(
        player.onDurationChanged.listen(
          (duration) => _update(duration: duration),
        ),
      )
      ..add(player.onPlayerComplete.listen((_) => _completed()));
    return player;
  }

  void _completed() {
    if (_playing == this) _playing = null;
    unawaited(_removeCopy());
  }

  void _update({PlayerState? state, Duration? position, Duration? duration}) {
    final old = playback.value;
    playback.value = VoicePlayback(
      state: state ?? old.state,
      position: position ?? old.position,
      duration: duration ?? old.duration,
    );
  }

  Future<void> _removeCopy() async {
    final copy = _copy;
    _copy = null;
    if (copy != null) await copies?.removeOpenCopy(copy);
  }
}
