import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../crypto/identity_store.dart';

enum DeviceKind { camera, microphone, speaker }

/// A camera, microphone or audio output known to the system.
@immutable
class MediaDevice {
  const MediaDevice({
    required this.id,
    required this.label,
    required this.kind,
  });

  final String id;
  final String label;
  final DeviceKind kind;
}

/// Which devices the user chose; `null` means the system default.
@immutable
class DeviceSelection {
  const DeviceSelection({this.cameraId, this.microphoneId, this.speakerId});

  final String? cameraId;
  final String? microphoneId;
  final String? speakerId;

  String? idFor(DeviceKind kind) => switch (kind) {
    DeviceKind.camera => cameraId,
    DeviceKind.microphone => microphoneId,
    DeviceKind.speaker => speakerId,
  };

  DeviceSelection withDevice(DeviceKind kind, String? id) => DeviceSelection(
    cameraId: kind == DeviceKind.camera ? id : cameraId,
    microphoneId: kind == DeviceKind.microphone ? id : microphoneId,
    speakerId: kind == DeviceKind.speaker ? id : speakerId,
  );
}

/// Lists devices and reports when they are plugged in or removed.
abstract interface class DeviceLister {
  Future<List<MediaDevice>> list();
  Stream<void> get changes;
}

class WebRtcDeviceLister implements DeviceLister {
  WebRtcDeviceLister() {
    rtc.navigator.mediaDevices.ondevicechange = (_) => _changes.add(null);
  }

  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<MediaDevice>> list() async {
    final devices = await rtc.navigator.mediaDevices.enumerateDevices();
    final result = <MediaDevice>[];
    for (final device in devices) {
      final kind = switch (device.kind) {
        'videoinput' => DeviceKind.camera,
        'audioinput' => DeviceKind.microphone,
        'audiooutput' => DeviceKind.speaker,
        _ => null,
      };
      // Browsers list "default"/"communications" aliases; skip them.
      if (kind == null ||
          device.deviceId.isEmpty ||
          device.deviceId == 'default' ||
          device.deviceId == 'communications') {
        continue;
      }
      final count = result.where((d) => d.kind == kind).length + 1;
      result.add(
        MediaDevice(
          id: device.deviceId,
          label: device.label.isNotEmpty
              ? device.label
              : switch (kind) {
                  DeviceKind.camera => 'Camera $count',
                  DeviceKind.microphone => 'Microphone $count',
                  DeviceKind.speaker => 'Speaker $count',
                },
          kind: kind,
        ),
      );
    }
    return result;
  }
}

/// The user's device choices (kept in the vault) and the devices currently
/// available. When a chosen device is unplugged, calls fall back to the
/// system default and [onDeviceGone] is told which kind disappeared.
class DeviceSettings extends ChangeNotifier {
  DeviceSettings(this._store, this._lister);

  static const String storageKey = 'sotto.devices.v1';

  final SecretStore _store;
  final DeviceLister _lister;
  StreamSubscription<void>? _subscription;
  List<MediaDevice> _available = const [];
  DeviceSelection _selection = const DeviceSelection();

  /// Called when a device that was in use is removed.
  void Function(DeviceKind kind)? onDeviceGone;

  List<MediaDevice> available(DeviceKind kind) =>
      _available.where((d) => d.kind == kind).toList();

  /// The stored choice, even if that device is unplugged right now.
  DeviceSelection get preferred => _selection;

  /// The choice to use now: unplugged devices fall back to the default.
  DeviceSelection get effective => DeviceSelection(
    cameraId: _present(_selection.cameraId),
    microphoneId: _present(_selection.microphoneId),
    speakerId: _present(_selection.speakerId),
  );

  String? _present(String? id) =>
      id != null && _available.any((d) => d.id == id) ? id : null;

  Future<void> load() async {
    final stored = await _store.read(storageKey);
    if (stored != null) {
      try {
        final json = jsonDecode(stored) as Map<String, dynamic>;
        _selection = DeviceSelection(
          cameraId: json['camera'] as String?,
          microphoneId: json['mic'] as String?,
          speakerId: json['speaker'] as String?,
        );
      } catch (_) {
        // Use the defaults.
      }
    }
    _subscription ??= _lister.changes.listen((_) => refresh());
    await refresh();
  }

  /// Re-reads the device list (also after camera/mic permission is granted,
  /// when browsers start showing device names).
  Future<void> refresh() async {
    final before = effective;
    try {
      _available = await _lister.list();
    } catch (_) {
      _available = const [];
    }
    final after = effective;
    for (final kind in DeviceKind.values) {
      if (before.idFor(kind) != null && after.idFor(kind) == null) {
        onDeviceGone?.call(kind);
      }
    }
    notifyListeners();
  }

  Future<void> choose(DeviceKind kind, String? id) async {
    _selection = _selection.withDevice(kind, id);
    notifyListeners();
    await _store.write(
      storageKey,
      jsonEncode({
        'camera': _selection.cameraId,
        'mic': _selection.microphoneId,
        'speaker': _selection.speakerId,
      }),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
