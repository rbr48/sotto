import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/app/app_controller.dart';
import 'package:sotto/diagnostics/event_log.dart';
import 'package:sotto/diagnostics/report.dart';
import 'package:sotto/diagnostics/ui/diagnostic_report_dialog.dart';
import 'package:sotto/storage/browser_storage.dart';

import '../call/devices_test.dart' show FakeLister;

void main() {
  test('the event log keeps the latest entries, in UTC', () {
    var now = DateTime.utc(2026, 10, 8, 9);
    final log = EventLog(capacity: 3, clock: () => now);
    for (var i = 0; i < 5; i++) {
      log.add('event $i');
      now = now.add(const Duration(seconds: 1));
    }
    expect(log.entries.map((e) => e.event), ['event 2', 'event 3', 'event 4']);
    expect(log.entries.first.at.isUtc, isTrue);
  });

  test('the report lists facts and events, and skips unknown facts', () {
    final report = DiagnosticReport.build(
      version: '0.1.2',
      platform: 'android (14)',
      facts: {'Relay connection': 'online', 'Call route': null},
      events: [
        (at: DateTime.utc(2026, 10, 8, 9, 0, 1, 500), event: 'relay online'),
      ],
      now: DateTime.utc(2026, 10, 8, 9, 5),
    );
    expect(report, contains('Version: 0.1.2'));
    expect(report, contains('Relay connection: online'));
    expect(report, isNot(contains('Call route')));
    expect(report, contains('2026-10-08T09:00:01Z  relay online'));
  });

  test("the app's report has no name, practice, ID or links", () async {
    final app = AppController(
      relayUrl: Uri.parse('ws://relay.test/relay'),
      linkBase: Uri.parse('https://relay.test/'),
      persistent: false,
      browserStorage: MemoryBrowserStorage(),
      deviceLister: FakeLister.new,
      startCalls: false,
    );
    await app.start();
    await app.completeOnboarding(
      name: 'Dr Meera Rao',
      practice: 'Lotus Clinic',
    );
    final report = appDiagnosticReport(app);
    expect(report, contains('Server: relay.test'));
    expect(report, contains('Data kept on this device: no (browser session)'));
    for (final secret in ['Meera', 'Lotus', '#g=', '#c=', '?call=']) {
      expect(report, isNot(contains(secret)));
    }
    app.dispose();
  });
}
