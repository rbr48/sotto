import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/call/call_controller.dart';
import 'package:sotto/call/devices.dart';
import 'package:sotto/call/ui/common.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

import 'devices_test.dart' show FakeLister;

void main() {
  testWidgets(
    'in Settings, scrolling over the device choices scrolls the page',
    (tester) async {
      final devices = DeviceSettings(
        MemorySecretStore(),
        FakeLister()
          ..devices = [
            for (var i = 0; i < 6; i++)
              MediaDevice(
                id: 'c$i',
                label: 'Camera $i',
                kind: DeviceKind.camera,
              ),
          ],
      );
      await tester.runAsync(devices.load);
      final calls = CallController(
        relayUrl: Uri.parse('ws://localhost:1/relay'),
        linkBase: Uri.parse('http://localhost:1/'),
        devices: devices,
      );
      final page = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: page,
              children: [
                const SizedBox(height: 300),
                DevicePicker(controller: calls, embedded: true),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      );
      // Only the page scrolls: no list of its own inside it.
      expect(find.byType(Scrollable), findsOneWidget);

      await tester.drag(find.text('Camera 2'), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(page.offset, greaterThan(300));
    },
  );
}
