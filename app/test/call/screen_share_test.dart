import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/call/screen_share.dart';

import 'fakes.dart';

void main() {
  test('screen sharing is offered only in a build that has it, on a platform that can capture', () {
    // The default build (no SOTTO_SCREEN_SHARE) never offers it.
    expect(screenShareBuildEnabled, isFalse);
    expect(screenShareOffered(web: true, desktop: true), isFalse);
    expect(screenShareOffered(web: false, desktop: false), isFalse);
  });

  test(
    'toggling starts the share, then stops it and gives the camera back',
    () async {
      final media = FakeMediaEngine();
      expect(media.sharingScreen, isFalse);

      expect(await changeScreenShare(media), isTrue);
      expect(media.sharingScreen, isTrue);

      expect(await changeScreenShare(media), isTrue);
      expect(media.sharingScreen, isFalse);
      expect(media.log, ['startScreenShare', 'stopScreenShare']);
    },
  );

  test('a refused capture leaves the call as it was and reports it', () async {
    final media = FakeMediaEngine()..screenShareRefused = true;

    expect(await changeScreenShare(media), isFalse);
    expect(media.sharingScreen, isFalse);
  });
}
