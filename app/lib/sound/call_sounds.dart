import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../call/call_manager.dart';
import '../core/test_hooks.dart';

enum Sound {
  /// Incoming call (looped).
  ringtone('ringtone.wav'),

  /// Our outgoing call is ringing on the other device (looped).
  ringback('ringback.wav'),

  /// A guest knocked.
  knock('knock.wav'),

  /// A call was answered automatically.
  answered('answered.wav');

  const Sound(this.file);
  final String file;
}

/// Plays sounds. Implemented with audioplayers; tests use a fake.
abstract interface class SoundOutput {
  Future<void> loop(Sound sound);
  Future<void> playOnce(Sound sound);
  Future<void> stopLoop();
  void dispose();
}

class AudioplayersOutput implements SoundOutput {
  final _loop = AudioPlayer(playerId: 'sotto-loop');
  final _cues = AudioPlayer(playerId: 'sotto-cue');

  @override
  Future<void> loop(Sound sound) async {
    await _loop.setReleaseMode(ReleaseMode.loop);
    await _loop.play(AssetSource('sounds/${sound.file}'));
  }

  @override
  Future<void> playOnce(Sound sound) async {
    await _cues.stop();
    await _cues.play(AssetSource('sounds/${sound.file}'));
  }

  @override
  Future<void> stopLoop() => _loop.stop();

  @override
  void dispose() {
    unawaited(_loop.dispose());
    unawaited(_cues.dispose());
  }
}

/// Decides which sound to play: the ringtone while a call rings here, the
/// ringback tone while ours rings there, a chime when a guest knocks or a
/// call is answered automatically. Sounds never stop a call from working:
/// playback errors (no audio device, autoplay blocked) are ignored.
class CallSounds {
  CallSounds(this._output, {bool Function()? enabled})
    : _enabled = enabled ?? (() => true);

  final SoundOutput _output;
  final bool Function() _enabled;
  Sound? _looping;

  /// The looping sound, if any (for tests and the UI).
  Sound? get looping => _looping;

  /// Call with every call state change.
  void onCallState(CallState state, {required bool autoAnswered}) {
    final wanted = switch (state.phase) {
      CallPhase.incoming => Sound.ringtone,
      CallPhase.ringing => Sound.ringback,
      _ => null,
    };
    if (wanted != _looping) {
      _looping = wanted;
      publishForTests('sound', wanted?.name ?? 'none');
      _guard(
        wanted == null || !_enabled()
            ? _output.stopLoop()
            : _output.loop(wanted),
      );
    }
    if (state.phase == CallPhase.connecting && autoAnswered) {
      _cue(Sound.answered);
    }
  }

  /// A new guest is waiting.
  void onKnock() => _cue(Sound.knock);

  void _cue(Sound sound) {
    publishForTests('cue', sound.name);
    if (_enabled()) _guard(_output.playOnce(sound));
  }

  void _guard(Future<void> playback) => unawaited(
    playback.catchError((Object e) {
      debugPrint('Sound not played: $e');
    }),
  );

  void dispose() {
    _guard(_output.stopLoop());
    _output.dispose();
  }
}
