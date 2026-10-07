import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/config.dart';

void main() {
  test(
    'derives the relay address from the page the web app was loaded from',
    () {
      expect(
        SottoConfig.relayUrlFor(
          Uri.parse('https://sotto.izhaanintellect.fun/some/page?x=1#y'),
        ).toString(),
        'wss://sotto.izhaanintellect.fun/relay',
      );
      expect(
        SottoConfig.relayUrlFor(Uri.parse('http://localhost:8080/')).toString(),
        'ws://localhost:8080/relay',
      );
      expect(
        SottoConfig.relayUrlFor(Uri.parse('file:///index.html')).toString(),
        'wss://sotto.izhaanintellect.fun/relay',
      );
    },
  );

  test('defaults to the Sotto test server outside the browser', () {
    expect(
      SottoConfig.relayUrl.toString(),
      'wss://sotto.izhaanintellect.fun/relay',
    );
    expect(
      SottoConfig.linkBase.toString(),
      'https://sotto.izhaanintellect.fun/',
    );
  });
}
