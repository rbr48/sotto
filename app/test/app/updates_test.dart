import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/app/app_controller.dart';
import 'package:sotto/core/update_check.dart';
import 'package:sotto/storage/browser_storage.dart';

import '../call/devices_test.dart' show FakeLister;

void main() {
  var checks = 0;
  var latest = 'v0.1.2';
  UpdateChecker checker() => UpdateChecker(
    endpoint: Uri.parse('https://releases.test/latest'),
    fetch: (_) async {
      checks++;
      return '{"tag_name":"$latest","html_url":"https://releases.test/$latest"}';
    },
  );

  Future<AppController> ready() async {
    final app = AppController(
      relayUrl: Uri.parse('ws://localhost:1/relay'),
      linkBase: Uri.parse('http://localhost:1/'),
      persistent: false,
      browserStorage: MemoryBrowserStorage(),
      deviceLister: FakeLister.new,
      startCalls: false,
      updateChecker: checker(),
    );
    await app.start();
    await app.completeOnboarding(name: 'Dr Rao');
    await pumpEventQueue();
    return app;
  }

  setUp(() {
    checks = 0;
    latest = 'v0.1.2';
  });

  test(
    'offers a newer release; "Not now" hides it until the next one',
    () async {
      latest = 'v9.0.0';
      final app = await ready();
      expect(checks, 1, reason: 'checked once the app is ready');
      expect(app.availableUpdate?.version, '9.0.0');

      await app.dismissUpdate();
      expect(app.availableUpdate, isNull);

      latest = 'v9.0.1';
      await app.checkForUpdates();
      expect(app.availableUpdate?.version, '9.0.1');
      app.dispose();
    },
  );

  test('nothing when up to date; switched off: no checks', () async {
    final app = await ready();
    expect(app.availableUpdate, isNull);

    await app.setDesktopPrefs(app.desktopPrefs.copyWith(checkUpdates: false));
    final before = checks;
    latest = 'v9.0.0';
    await pumpEventQueue();
    expect(checks, before);
    expect(app.availableUpdate, isNull);

    await app.setDesktopPrefs(app.desktopPrefs.copyWith(checkUpdates: true));
    await pumpEventQueue();
    expect(app.availableUpdate?.version, '9.0.0');
    app.dispose();
  });
}
