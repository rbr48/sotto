import 'package:sodium/sodium_sumo.dart';

export 'envelope.dart';
export 'identity.dart';
export 'identity_store.dart';
export 'replay_guard.dart';
export 'safety_number.dart';

/// Loads libsodium (native library, or sodium.js on the web).
abstract final class SottoCrypto {
  static Future<Sodium>? _instance;

  /// Every platform uses the full ("sumo") API of libsodium, which adds
  /// Argon2id for backups, chat exports and the app lock. The web build ships
  /// the sumo sodium.js (`web/sodium.js`, checked against the package's hash
  /// by `dart run sodium:update_web --sumo`).
  static Future<Sodium> init() =>
      _instance ??= Future.value(SodiumSumoInit.init());

  /// Argon2id password hashing. Null only if the library lacks it.
  static SodiumSumo? passwordHashing(Sodium sodium) =>
      sodium is SodiumSumo ? sodium : null;
}
