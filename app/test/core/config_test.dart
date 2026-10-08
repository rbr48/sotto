import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/config.dart';

void main() {
  test(
    'derives the relay address from the page the web app was loaded from',
    () {
      expect(
        SottoConfig.relayUrlFor(
          Uri.parse('https://sotto.example.org/some/page?x=1#y'),
        ).toString(),
        'wss://sotto.example.org/relay',
      );
      expect(
        SottoConfig.relayUrlFor(Uri.parse('http://localhost:8080/')).toString(),
        'ws://localhost:8080/relay',
      );
      expect(
        SottoConfig.relayUrlFor(Uri.parse('file:///index.html')).toString(),
        'wss://call.sottocall.com/relay',
      );
    },
  );

  test('defaults to the Sotto server outside the browser', () {
    expect(SottoConfig.relayUrl.toString(), 'wss://call.sottocall.com/relay');
    expect(SottoConfig.linkBase.toString(), 'https://call.sottocall.com/');
  });
}
