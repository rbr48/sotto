import 'media_engine.dart';

/// Decides how much video to send from the upload quality sampled every
/// couple of seconds ([QualitySample.uploadAt]).
///
/// It steps down quickly and back up slowly, so a short dip doesn't make the
/// picture jump, and a call on a weak network keeps its voice: after poor
/// samples at the lowest level, video pauses until the upload recovers.
class VideoAdapter {
  /// Consecutive samples needed to step down on a poor or fair upload, and
  /// to step back up on a good one.
  static const poorToStepDown = 2;
  static const fairToStepDown = 3;
  static const poorToPause = 3;
  static const goodToStepUp = 5;
  static const goodToResume = 8;

  VideoLevel _level = VideoLevel.full;
  CallQuality? _streakOf;
  int _streak = 0;

  VideoLevel get level => _level;

  /// Feeds one sample; returns the new level when it changes.
  VideoLevel? onSample(CallQuality? upload) {
    if (upload == null) return null;
    if (upload == _streakOf) {
      _streak++;
    } else {
      _streakOf = upload;
      _streak = 1;
    }
    final next = _next(upload);
    if (next == null || next == _level) return null;
    _level = next;
    _streak = 0;
    return next;
  }

  /// Back to full video (a new call, or a new network path).
  void reset() {
    _level = VideoLevel.full;
    _streakOf = null;
    _streak = 0;
  }

  VideoLevel? _next(CallQuality upload) {
    switch (upload) {
      case CallQuality.poor:
        if (_level == VideoLevel.low) {
          return _streak >= poorToPause ? VideoLevel.paused : null;
        }
        if (_level == VideoLevel.paused) return null;
        return _streak >= poorToStepDown ? _down(_level) : null;
      case CallQuality.fair:
        // A fair upload lowers full video once, but never pauses it.
        return _level == VideoLevel.full && _streak >= fairToStepDown
            ? VideoLevel.reduced
            : null;
      case CallQuality.good:
        final needed = _level == VideoLevel.paused
            ? goodToResume
            : goodToStepUp;
        return _level != VideoLevel.full && _streak >= needed
            ? _up(_level)
            : null;
    }
  }

  static VideoLevel _down(VideoLevel level) => switch (level) {
    VideoLevel.full => VideoLevel.reduced,
    VideoLevel.reduced => VideoLevel.low,
    VideoLevel.low || VideoLevel.paused => VideoLevel.paused,
  };

  static VideoLevel _up(VideoLevel level) => switch (level) {
    VideoLevel.paused => VideoLevel.low,
    VideoLevel.low => VideoLevel.reduced,
    VideoLevel.reduced || VideoLevel.full => VideoLevel.full,
  };
}
