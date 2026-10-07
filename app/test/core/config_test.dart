import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/config.dart';

void main() {
  test(
    'derives the relay address from the page the web app was loaded from',
    () {
      expect(
        SottoConfig.devRoomsUrlFor(
          Uri.parse('https://sotto.izhaanintellect.fun/some/page?x=1#y'),
        ),
        'wss://sotto.izhaanintellect.fun/dev/rooms',
      );
      expect(
        SottoConfig.devRoomsUrlFor(Uri.parse('http://localhost:8080/')),
        'ws://localhost:8080/dev/rooms',
      );
      expect(
        SottoConfig.devRoomsUrlFor(Uri.parse('file:///index.html')),
        'wss://sotto.izhaanintellect.fun/dev/rooms',
      );
    },
  );

  test('defaults to the Sotto test server outside the browser', () {
    expect(
      SottoConfig.devRoomsUrl,
      'wss://sotto.izhaanintellect.fun/dev/rooms',
    );
  });
}
