import 'package:flutter/foundation.dart';
import 'package:sodium/sodium.dart';
import 'package:sodium/sodium_sumo.dart';

export 'envelope.dart';
export 'identity.dart';
export 'identity_store.dart';
export 'replay_guard.dart';
export 'safety_number.dart';

/// Loads libsodium (native library, or sodium.js on the web).
abstract final class SottoCrypto {
  static Future<Sodium>? _instance;

  /// The native apps use the full ("sumo") API of the bundled libsodium,
  /// which adds Argon2id for backups and the app lock. The web build ships
  /// the smaller sodium.js without it: browsers never handle backups.
  static Future<Sodium> init() => _instance ??= Future.value(
    kIsWeb ? SodiumInit.init() : SodiumSumoInit.init(),
  );

  /// Argon2id password hashing, or `null` where it isn't available (web).
  static SodiumSumo? passwordHashing(Sodium sodium) =>
      sodium is SodiumSumo ? sodium : null;
}
