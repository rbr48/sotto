import 'dart:convert';

import '../crypto/encoding.dart';
import '../crypto/identity.dart';
import '../crypto/identity_store.dart';
import 'contact_link.dart';

/// The people this device looked up from short links (their keys, name and
/// organisation as their app last sent them), kept in the encrypted
/// settings so a short link still works while its owner is offline.
///
/// Only verified lookups are stored, and only on this device.
class ProfileCache {
  ProfileCache(this._store, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const String storageKey = 'sotto.profiles.v1';

  /// Older entries are forgotten beyond this many.
  static const int maxEntries = 200;

  final SecretStore _store;
  final DateTime Function() _clock;
  Map<String, Map<String, dynamic>>? _entries;

  Future<Map<String, Map<String, dynamic>>> _load() async {
    if (_entries case final entries?) return entries;
    var entries = <String, Map<String, dynamic>>{};
    try {
      final stored = await _store.read(storageKey);
      if (stored != null) {
        entries = {
          for (final MapEntry(:key, :value)
              in (jsonDecode(stored) as Map<String, dynamic>).entries)
            key: value as Map<String, dynamic>,
        };
      }
    } catch (_) {
      // Unreadable: start over (it is only a cache).
    }
    return _entries = entries;
  }

  /// The last known details of the person whose relay ID is [id].
  Future<ContactInvite?> lookup(String id) async {
    final entry = (await _load())[id];
    if (entry == null) return null;
    try {
      final identity = PublicIdentity(
        signKey: b64Decode(entry['sign'] as String),
        boxKey: b64Decode(entry['box'] as String),
      );
      if (identity.id != id) return null;
      return ContactInvite(
        identity: identity,
        name: entry['n'] as String?,
        organisation: entry['o'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Remembers a verified lookup (the newest replaces the old one).
  Future<void> remember(ContactInvite invite) async {
    final entries = await _load();
    final id = invite.identity.id;
    entries
      ..remove(id)
      ..[id] = {
        'sign': b64Encode(invite.identity.signKey),
        'box': b64Encode(invite.identity.boxKey),
        'n': ?invite.name,
        'o': ?invite.organisation,
        't': _clock().toUtc().toIso8601String(),
      };
    while (entries.length > maxEntries) {
      entries.remove(entries.keys.first);
    }
    try {
      await _store.write(storageKey, jsonEncode(entries));
    } catch (_) {
      // Not persisted: still used until the app restarts.
    }
  }
}
