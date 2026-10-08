import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/call/call_manager.dart';
import 'package:sotto/call/screen_awake.dart';

class _Screen implements ScreenAwake {
  final changes = <bool>[];

  @override
  Future<void> keepOn(bool on) async => changes.add(on);
}

void main() {
  test('a video call keeps the screen on until it ends', () {
    final screen = _Screen();
    final keeper = VideoCallScreen(screen);
    keeper.update(CallState.idle);
    expect(screen.changes, isEmpty);
    for (final phase in [
      CallPhase.calling,
      CallPhase.ringing,
      CallPhase.connecting,
      CallPhase.connected,
    ]) {
      keeper.update(CallState(phase: phase));
    }
    expect(screen.changes, [true], reason: 'turned on once');
    keeper.update(const CallState(phase: CallPhase.ended));
    expect(screen.changes, [true, false]);
    expect(keeper.keptOn, isFalse);
  });

  test('an incoming video call keeps it on; a voice call never does', () {
    final screen = _Screen();
    final keeper = VideoCallScreen(screen);
    keeper.update(const CallState(phase: CallPhase.connected, video: false));
    expect(screen.changes, isEmpty);
    keeper.update(const CallState(phase: CallPhase.incoming));
    expect(screen.changes, [true]);
    keeper.release();
    expect(screen.changes, [true, false]);
    keeper.release();
    expect(screen.changes, [true, false], reason: 'released once');
  });
}
