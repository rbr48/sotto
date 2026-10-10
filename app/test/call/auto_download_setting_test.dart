import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/call/call_controller.dart';
import 'package:sotto/chat/chat_session.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

void main() {
  test('"Download files automatically" is off unless switched on, and is '
      'kept', () async {
    final settings = MemorySecretStore();
    final calls = CallController(
      relayUrl: Uri.parse('ws://localhost:1/relay'),
      linkBase: Uri.parse('http://localhost:1/'),
      settings: settings,
    );
    addTearDown(calls.dispose);
    expect(calls.autoDownloadFiles, isFalse);
    expect(
      await settings.read(CallController.autoDownloadFilesSetting),
      isNull,
    );

    var notified = 0;
    calls.addListener(() => notified++);
    await calls.setAutoDownloadFiles(true);
    expect(calls.autoDownloadFiles, isTrue);
    expect(notified, greaterThan(0));
    expect(await settings.read(CallController.autoDownloadFilesSetting), '1');

    await calls.setAutoDownloadFiles(false);
    expect(calls.autoDownloadFiles, isFalse);
    expect(await settings.read(CallController.autoDownloadFilesSetting), '0');

    expect(
      calls.autoDownloadMaxMegabytes,
      ChatSession.autoAcceptMaxBytes ~/ (1024 * 1024),
    );
  });
}
