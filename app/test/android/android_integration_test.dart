import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/android/android_integration.dart';
import 'package:sotto/android/android_platform.dart';
import 'package:sotto/app/app_controller.dart';
import 'package:sotto/chat/chat_arrival.dart';
import 'package:sotto/storage/browser_storage.dart';

import '../call/devices_test.dart' show FakeLister;

class FakeAndroid implements AndroidPlatform {
  final log = <String>[];
  final actionsController = StreamController<String>.broadcast();
  AndroidStatus current = const AndroidStatus(notificationsAllowed: false);

  @override
  Stream<String> get actions => actionsController.stream;

  @override
  Future<void> setRingWhenClosed(bool on) async => log.add('ring $on');

  @override
  Future<AndroidStatus> status() async => current;

  @override
  Future<void> requestNotifications() async => log.add('ask notifications');

  @override
  Future<void> requestBatteryExemption() async => log.add('ask battery');

  @override
  Future<void> openFullScreenSettings() async => log.add('full screen');

  @override
  Future<void> showIncomingCall({
    required String title,
    required String body,
    required bool video,
  }) async => log.add('ring: $title / $body');

  @override
  Future<void> cancelIncomingCall() async => log.add('stop ringing');

  @override
  Future<void> showKnock({required String title, required String body}) async =>
      log.add('knock: $title');

  @override
  Future<void> cancelKnock() async => log.add('cancel knock');

  @override
  Future<void> showMessage({
    required String title,
    required String body,
  }) async => log.add('message: $title / $body');

  @override
  Future<void> cancelMessage() async => log.add('cancel message');

  @override
  Future<void> callFinished() async => log.add('call finished');

  @override
  Future<void> startCallService({
    required String title,
    required String name,
    DateTime? since,
    bool video = false,
  }) async => log.add('call service: $title / $name / ${since != null}');

  @override
  Future<void> stopCallService() async => log.add('call service stopped');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(AppController, FakeAndroid, AndroidIntegration)> started() async {
    final app = AppController(
      relayUrl: Uri.parse('ws://localhost:1/relay'),
      linkBase: Uri.parse('http://localhost:1/'),
      persistent: false,
      browserStorage: MemoryBrowserStorage(),
      deviceLister: FakeLister.new,
      startCalls: false,
    );
    await app.start();
    await app.completeOnboarding(name: 'Dr Rao');
    final platform = FakeAndroid();
    final android = AndroidIntegration(app, platform: platform);
    await android.start();
    return (app, platform, android);
  }

  test(
    'the background service follows "Ring even when Sotto is closed"',
    () async {
      final (app, platform, android) = await started();
      expect(platform.log, contains('ring true'), reason: 'on by default');

      await app.setDesktopPrefs(
        app.desktopPrefs.copyWith(ringWhenClosed: false),
      );
      expect(platform.log.last, 'ring false');
      await app.setDesktopPrefs(app.desktopPrefs.copyWith(showNames: true));
      expect(
        platform.log.where((e) => e.startsWith('ring ')),
        hasLength(2),
        reason: 'only changes are sent',
      );
      android.dispose();
    },
  );

  test('asks for notifications once, and only while the user looks', () async {
    final (app, platform, android) = await started();
    expect(
      platform.log,
      isNot(contains('ask notifications')),
      reason: 'started in the background (e.g. at boot)',
    );

    android.inFront = true;
    await app.setDesktopPrefs(app.desktopPrefs.copyWith(ringWhenClosed: false));
    await app.setDesktopPrefs(app.desktopPrefs.copyWith(ringWhenClosed: true));
    await pumpEventQueue();
    await app.setDesktopPrefs(app.desktopPrefs.copyWith(ringWhenClosed: false));
    await app.setDesktopPrefs(app.desktopPrefs.copyWith(ringWhenClosed: true));
    await pumpEventQueue();
    expect(platform.log.where((e) => e == 'ask notifications'), hasLength(1));

    platform.current = const AndroidStatus(batteryUnrestricted: false);
    android.inFront = false;
    android.inFront = true; // back in front: refreshed
    await pumpEventQueue();
    expect(android.status.batteryUnrestricted, isFalse);
    expect(android.status.ready, isFalse);
    expect(platform.log, contains('cancel knock'));
    android.dispose();
  });

  test(
    'a message from a contact: a notice only while in the background',
    () async {
      final (app, platform, android) = await started();
      const arrival = ChatArrival(senderName: 'Meera Rao', viewing: false);

      android.onChatMessage(arrival);
      expect(
        platform.log,
        contains('message: New message / Open Sotto to read it.'),
        reason: 'names are off by default',
      );

      await app.setDesktopPrefs(app.desktopPrefs.copyWith(showNames: true));
      android.onChatMessage(arrival);
      expect(
        platform.log,
        contains(
          'message: New message from Meera Rao / Open Sotto to read it.',
        ),
      );

      android.inFront = true;
      await pumpEventQueue();
      expect(platform.log, contains('cancel message'));
      android.onChatMessage(
        const ChatArrival(senderName: 'Meera Rao', viewing: true),
      );
      expect(
        platform.log.where((e) => e.startsWith('message:')),
        hasLength(2),
        reason: 'the open chat, in front, needs no notice',
      );
      android.onChatMessage(
        const ChatArrival(senderName: 'Meera Rao', viewing: false),
      );
      expect(
        platform.log.where((e) => e.startsWith('message:')),
        hasLength(3),
        reason: 'another chat in front still gets one',
      );
      android.dispose();
    },
  );
}
