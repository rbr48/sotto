import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../crypto/encoding.dart';
import '../crypto/identity.dart';
import '../crypto/identity_store.dart';

/// How an incoming call is answered automatically.
@immutable
class AutoAnswer {
  const AutoAnswer({required this.delay, required this.video});

  /// Rings this long first; the user can still decline.
  final Duration delay;

  /// Whether to answer with the camera on.
  final bool video;
}

/// Someone whose calls may be answered automatically. Only added by the user,
/// after comparing safety numbers; stored on this device only.
@immutable
class TrustedCaller {
  const TrustedCaller({
    required this.identity,
    required this.name,
    this.allowVideo = false,
  });

  final PublicIdentity identity;
  final String name;

  /// Answer with the camera on (otherwise voice only).
  final bool allowVideo;

  TrustedCaller copyWith({String? name, bool? allowVideo}) => TrustedCaller(
    identity: identity,
    name: name ?? this.name,
    allowVideo: allowVideo ?? this.allowVideo,
  );

  Map<String, Object> toJson() => {
    'sign': b64Encode(identity.signKey),
    'box': b64Encode(identity.boxKey),
    'name': name,
    'video': allowVideo,
  };

  static TrustedCaller fromJson(Map<String, dynamic> json) => TrustedCaller(
    identity: PublicIdentity(
      signKey: b64Decode(json['sign'] as String),
      boxKey: b64Decode(json['box'] as String),
    ),
    name: json['name'] as String,
    allowVideo: json['video'] as bool? ?? false,
  );
}

/// The user's trusted callers and auto-answer settings, kept in the
/// device's secret store. Nothing here is ever sent to anyone.
class TrustedCallers extends ChangeNotifier {
  TrustedCallers(this._secrets);

  static const String storageKey = 'sotto.trusted_callers.v1';
  static const int maxDelaySeconds = 10;
  static const int defaultDelaySeconds = 5;

  final SecretStore _secrets;
  final List<TrustedCaller> _callers = [];
  bool _enabled = false;
  int _delaySeconds = defaultDelaySeconds;

  List<TrustedCaller> get callers => List.unmodifiable(_callers);

  /// "Auto-answer calls from trusted callers" (off by default).
  bool get enabled => _enabled;

  /// How long a trusted call rings before it is answered.
  int get delaySeconds => _delaySeconds;

  TrustedCaller? find(PublicIdentity identity) =>
      _callers.where((c) => c.identity == identity).firstOrNull;

  Future<void> load() async {
    final stored = await _secrets.read(storageKey);
    if (stored == null) return;
    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      _enabled = json['enabled'] as bool? ?? false;
      _delaySeconds = (json['delay'] as int? ?? defaultDelaySeconds).clamp(
        0,
        maxDelaySeconds,
      );
      _callers
        ..clear()
        ..addAll(
          (json['callers'] as List<dynamic>).map(
            (c) => TrustedCaller.fromJson(c as Map<String, dynamic>),
          ),
        );
    } catch (_) {
      // Unreadable settings: keep auto-answer off.
      _enabled = false;
      _callers.clear();
    }
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    await _secrets.write(
      storageKey,
      jsonEncode({
        'enabled': _enabled,
        'delay': _delaySeconds,
        'callers': [for (final c in _callers) c.toJson()],
      }),
    );
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await _save();
  }

  Future<void> setDelaySeconds(int seconds) async {
    _delaySeconds = seconds.clamp(0, maxDelaySeconds);
    await _save();
  }

  /// Adds or updates a trusted caller. The user must have confirmed that
  /// they compared the safety number with this person.
  Future<void> trust(TrustedCaller caller) async {
    _callers.removeWhere((c) => c.identity.id == caller.identity.id);
    _callers.add(caller);
    await _save();
  }

  Future<void> setAllowVideo(PublicIdentity identity, bool allow) async {
    final index = _callers.indexWhere((c) => c.identity == identity);
    if (index < 0) return;
    _callers[index] = _callers[index].copyWith(allowVideo: allow);
    await _save();
  }

  Future<void> remove(PublicIdentity identity) async {
    _callers.removeWhere((c) => c.identity.id == identity.id);
    await _save();
  }

  /// The auto-answer rule: only when switched on, only for an exact match of
  /// a trusted caller's keys, and voice only unless video is allowed for
  /// them. (Busy calls are rejected before this is asked.)
  AutoAnswer? decide(PublicIdentity caller, {required bool videoCall}) {
    if (!_enabled) return null;
    final trusted = find(caller);
    if (trusted == null) return null;
    return AutoAnswer(
      delay: Duration(seconds: _delaySeconds),
      video: videoCall && trusted.allowVideo,
    );
  }
}
