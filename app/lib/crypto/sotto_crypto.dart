import 'package:sodium/sodium.dart';

export 'envelope.dart';
export 'identity.dart';
export 'identity_store.dart';
export 'replay_guard.dart';
export 'safety_number.dart';

/// Loads libsodium (native library, or sodium.js on the web).
abstract final class SottoCrypto {
  static Future<Sodium>? _instance;

  static Future<Sodium> init() => _instance ??= Future.value(SodiumInit.init());
}
