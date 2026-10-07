import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/call/devices.dart';
import 'package:sotto/call/media_engine.dart';
import 'package:sotto/crypto/identity_store.dart';

class FakeLister implements DeviceLister {
  List<MediaDevice> devices = [];
  final controller = StreamController<void>.broadcast();

  @override
  Future<List<MediaDevice>> list() async => devices;

  @override
  Stream<void> get changes => controller.stream;
}

void main() {
  const builtIn = MediaDevice(
    id: 'cam1',
    label: 'Built-in',
    kind: DeviceKind.camera,
  );
  const usb = MediaDevice(
    id: 'cam2',
    label: 'USB camera',
    kind: DeviceKind.camera,
  );
  const headset = MediaDevice(
    id: 'mic2',
    label: 'Headset',
    kind: DeviceKind.microphone,
  );

  test(
    'choices are stored; unplugged devices fall back to the default',
    () async {
      final store = MemorySecretStore();
      final lister = FakeLister()..devices = [builtIn, usb, headset];
      final devices = DeviceSettings(store, lister);
      final gone = <DeviceKind>[];
      devices.onDeviceGone = gone.add;
      await devices.load();
      expect(devices.available(DeviceKind.camera).map((d) => d.label), [
        'Built-in',
        'USB camera',
      ]);

      await devices.choose(DeviceKind.camera, 'cam2');
      await devices.choose(DeviceKind.microphone, 'mic2');
      expect(devices.effective.cameraId, 'cam2');

      // Unplug the USB camera: the call falls back to the default camera.
      lister.devices = [builtIn, headset];
      lister.controller.add(null);
      await pumpEventQueue();
      expect(gone, [DeviceKind.camera]);
      expect(devices.effective.cameraId, isNull);
      expect(devices.preferred.cameraId, 'cam2');
      expect(devices.effective.microphoneId, 'mic2');

      // Plug it back in: it is used again.
      lister.devices = [builtIn, usb, headset];
      lister.controller.add(null);
      await pumpEventQueue();
      expect(devices.effective.cameraId, 'cam2');

      final reloaded = DeviceSettings(store, FakeLister()..devices = [usb]);
      await reloaded.load();
      expect(reloaded.effective.cameraId, 'cam2');
      expect(reloaded.effective.microphoneId, isNull);
      devices.dispose();
      reloaded.dispose();
    },
  );

  test('call quality thresholds', () {
    expect(const QualitySample().quality, isNull);
    expect(
      const QualitySample(
        roundTrip: Duration(milliseconds: 80),
        packetLoss: 0.0,
      ).quality,
      CallQuality.good,
    );
    expect(
      const QualitySample(roundTrip: Duration(milliseconds: 350)).quality,
      CallQuality.fair,
    );
    expect(const QualitySample(packetLoss: 0.05).quality, CallQuality.fair);
    expect(const QualitySample(packetLoss: 0.2).quality, CallQuality.poor);
    expect(
      const QualitySample(roundTrip: Duration(milliseconds: 900)).quality,
      CallQuality.poor,
    );
  });
}
