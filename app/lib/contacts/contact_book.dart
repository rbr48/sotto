import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../call/call_manager.dart';
import '../core/test_hooks.dart';
import '../crypto/encoding.dart';
import '../crypto/identity.dart';
import '../crypto/identity_store.dart';

/// A person in the user's contacts. Stored on this device only.
@immutable
class Contact {
  const Contact({
    required this.identity,
    required this.name,
    this.organisation = '',
    this.verified = false,
    this.autoAnswer = false,
    this.autoAnswerVideo = false,
    required this.addedAt,
  });

  final PublicIdentity identity;
  final String name;
  final String organisation;

  /// The user confirmed they compared the safety number with this person.
  final bool verified;

  /// Calls from this person may be answered automatically (only if
  /// [verified] and auto-answer is switched on).
  final bool autoAnswer;

  /// Answer with the camera on (otherwise voice only).
  final bool autoAnswerVideo;
  final DateTime addedAt;

  String get id => identity.id;

  /// "Name (Organisation)".
  String get label => organisation.isEmpty ? name : '$name ($organisation)';

  Contact copyWith({
    String? name,
    String? organisation,
    bool? verified,
    bool? autoAnswer,
    bool? autoAnswerVideo,
  }) => Contact(
    identity: identity,
    name: name ?? this.name,
    organisation: organisation ?? this.organisation,
    verified: verified ?? this.verified,
    autoAnswer: autoAnswer ?? this.autoAnswer,
    autoAnswerVideo: autoAnswerVideo ?? this.autoAnswerVideo,
    addedAt: addedAt,
  );

  Map<String, Object> toJson() => {
    'sign': b64Encode(identity.signKey),
    'box': b64Encode(identity.boxKey),
    'name': name,
    'org': organisation,
    'verified': verified,
    'auto': autoAnswer,
    'autoVideo': autoAnswerVideo,
    'added': addedAt.millisecondsSinceEpoch,
  };

  static Contact fromJson(Map<String, dynamic> json) => Contact(
    identity: PublicIdentity(
      signKey: b64Decode(json['sign'] as String),
      boxKey: b64Decode(json['box'] as String),
    ),
    name: json['name'] as String,
    organisation: json['org'] as String? ?? '',
    verified: json['verified'] as bool? ?? false,
    autoAnswer: json['auto'] as bool? ?? false,
    autoAnswerVideo: json['autoVideo'] as bool? ?? false,
    addedAt: DateTime.fromMillisecondsSinceEpoch(
      json['added'] as int? ?? 0,
      isUtc: true,
    ),
  );
}

/// The user's contacts and the auto-answer setting, kept in the vault.
/// Nothing here is ever sent to anyone.
///
/// Auto-answer rules: switched on by the user, only for contacts marked
/// verified (safety number compared) and chosen for auto-answer, exact key
/// match, voice only unless video is allowed for that person.
class ContactBook extends ChangeNotifier {
  ContactBook(this._store, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const String storageKey = 'sotto.contacts.v1';

  /// Where Phase 5B kept trusted callers; imported as verified contacts.
  static const String legacyTrustedKey = 'sotto.trusted_callers.v1';

  static const int maxDelaySeconds = 10;
  static const int defaultDelaySeconds = 5;

  final SecretStore _store;
  final DateTime Function() _clock;
  final List<Contact> _contacts = [];
  bool _autoAnswerEnabled = false;
  int _delaySeconds = defaultDelaySeconds;

  /// Contacts sorted by name.
  List<Contact> get contacts => List.unmodifiable(
    [..._contacts]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
  );

  /// "Auto-answer calls from trusted contacts" (off by default).
  bool get autoAnswerEnabled => _autoAnswerEnabled;

  /// How long a trusted call rings before it is answered.
  int get delaySeconds => _delaySeconds;

  /// Contacts whose calls may be answered automatically.
  List<Contact> get trusted =>
      contacts.where((c) => c.verified && c.autoAnswer).toList();

  Contact? find(PublicIdentity identity) =>
      _contacts.where((c) => c.identity == identity).firstOrNull;

  Future<void> load() async {
    _contacts.clear();
    final stored = await _store.read(storageKey);
    if (stored != null) {
      try {
        final json = jsonDecode(stored) as Map<String, dynamic>;
        _autoAnswerEnabled = json['autoAnswer'] as bool? ?? false;
        _delaySeconds = (json['delay'] as int? ?? defaultDelaySeconds).clamp(
          0,
          maxDelaySeconds,
        );
        for (final c in json['contacts'] as List<dynamic>) {
          _contacts.add(Contact.fromJson(c as Map<String, dynamic>));
        }
      } catch (_) {
        // Unreadable: keep auto-answer off rather than guess.
        _autoAnswerEnabled = false;
      }
    }
    await _importLegacyTrusted();
    notifyListeners();
  }

  /// Phase 5B trusted callers become verified contacts with auto-answer.
  Future<void> _importLegacyTrusted() async {
    final stored = await _store.read(legacyTrustedKey);
    if (stored == null) return;
    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      _autoAnswerEnabled |= json['enabled'] as bool? ?? false;
      _delaySeconds = (json['delay'] as int? ?? _delaySeconds).clamp(
        0,
        maxDelaySeconds,
      );
      for (final c in json['callers'] as List<dynamic>) {
        final caller = c as Map<String, dynamic>;
        final identity = PublicIdentity(
          signKey: b64Decode(caller['sign'] as String),
          boxKey: b64Decode(caller['box'] as String),
        );
        final existing = find(identity);
        _contacts.removeWhere((x) => x.identity == identity);
        _contacts.add(
          (existing ??
                  Contact(
                    identity: identity,
                    name: caller['name'] as String,
                    addedAt: _clock().toUtc(),
                  ))
              .copyWith(
                verified: true,
                autoAnswer: true,
                autoAnswerVideo: caller['video'] as bool? ?? false,
              ),
        );
      }
    } catch (_) {
      // Ignore a damaged legacy entry.
    }
    await _save();
    await _store.delete(legacyTrustedKey);
  }

  Future<void> _save() async {
    publishForTests('auto-answer', '$_autoAnswerEnabled');
    notifyListeners();
    await _store.write(
      storageKey,
      jsonEncode({
        'autoAnswer': _autoAnswerEnabled,
        'delay': _delaySeconds,
        'contacts': [for (final c in _contacts) c.toJson()],
      }),
    );
  }

  /// Adds a contact, or updates the name/organisation of an existing one
  /// (keeping its verification and auto-answer choices).
  Future<Contact> add(
    PublicIdentity identity, {
    required String name,
    String organisation = '',
    bool verified = false,
  }) async {
    final existing = find(identity);
    final contact =
        existing?.copyWith(
          name: name.trim(),
          organisation: organisation.trim(),
          verified: existing.verified || verified,
        ) ??
        Contact(
          identity: identity,
          name: name.trim(),
          organisation: organisation.trim(),
          verified: verified,
          addedAt: _clock().toUtc(),
        );
    _contacts
      ..removeWhere((c) => c.identity == identity)
      ..add(contact);
    await _save();
    return contact;
  }

  Future<void> update(Contact contact) async {
    final index = _contacts.indexWhere((c) => c.identity == contact.identity);
    if (index < 0) return;
    // Auto-answer is only possible for verified contacts.
    _contacts[index] = contact.verified
        ? contact
        : contact.copyWith(autoAnswer: false);
    await _save();
  }

  Future<void> remove(PublicIdentity identity) async {
    _contacts.removeWhere((c) => c.identity == identity);
    await _save();
  }

  /// Callers must have confirmed the app lock.
  Future<void> setAutoAnswerEnabled(bool enabled) async {
    _autoAnswerEnabled = enabled;
    await _save();
  }

  /// Callers must have confirmed the app lock.
  Future<void> setDelaySeconds(int seconds) async {
    _delaySeconds = seconds.clamp(0, maxDelaySeconds);
    await _save();
  }

  /// The auto-answer rule. (Busy calls are rejected before this is asked.)
  AutoAnswer? decide(PublicIdentity caller, {required bool videoCall}) {
    if (!_autoAnswerEnabled) return null;
    final contact = find(caller);
    if (contact == null || !contact.verified || !contact.autoAnswer) {
      return null;
    }
    return AutoAnswer(
      delay: Duration(seconds: _delaySeconds),
      video: videoCall && contact.autoAnswerVideo,
    );
  }
}
