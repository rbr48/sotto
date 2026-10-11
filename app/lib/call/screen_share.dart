import 'package:flutter/foundation.dart';

import 'media_engine.dart';

/// Whether this build offers screen sharing. Off unless built with
/// `--dart-define=SOTTO_SCREEN_SHARE=true`: it is a Pro feature, and it is not
/// sold until billing exists (`docs/FEATURES.md`).
const bool screenShareBuildEnabled = bool.fromEnvironment('SOTTO_SCREEN_SHARE');

/// Whether the call screen offers screen sharing here: the build has it, and
/// the platform can capture a screen (a browser, or a desktop app).
bool screenShareOffered({required bool web, required bool desktop}) =>
    screenShareBuildEnabled && (web || desktop);

/// Starts sharing the screen, or stops it if it is shared. Returns false when
/// the change did not happen (no camera to replace, or the capture was
/// refused), so the call screen can say so.
Future<bool> changeScreenShare(MediaEngine media) async {
  try {
    if (media.sharingScreen) {
      await media.stopScreenShare();
    } else {
      await media.startScreenShare();
    }
    return true;
  } catch (e) {
    debugPrint('screen share: $e');
    return false;
  }
}
