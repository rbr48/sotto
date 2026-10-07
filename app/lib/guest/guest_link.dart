import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../crypto/encoding.dart';
import '../crypto/identity.dart';
import '../crypto/identity_store.dart';

/// Why a guest link can't be used.
enum GuestLinkProblem {
  /// Not a Sotto guest link, or damaged.
  malformed,

  /// The signature doesn't match: the link was altered.
  badSignature,

  /// The link's validity window has passed.
  expired,

  /// The professional revoked the link (learned when knocking).
  revoked,

  /// A one-time link that was already used (learned when knocking).
  used,
}

class GuestLinkException implements Exception {
  const GuestLinkException(this.problem);
  final GuestLinkProblem problem;
  @override
  String toString() => 'GuestLinkException(${problem.name})';
}

/// A verified guest link, as seen by the guest.
///
/// Wire format (after `#g=` in the URL, so it never reaches a web server):
/// `base64url(JSON {v, card, lid, s, n, exp?, sig})`, where
/// `sig = Ed25519("sotto-link-v1\0" || JSON[sign, box, lid, s, n, exp])`
/// by the professional's identity key.
class GuestLink {
  const GuestLink({
    required this.host,
    required this.linkId,
    required this.secret,
    required this.hostName,
    this.expiresAt,
  });

  static const int version = 1;
  static const String fragmentKey = 'g';

  /// The professional the link belongs to.
  final PublicIdentity host;
  final String linkId;

  /// Proves to the professional's app that the guest holds this link.
  final String secret;

  /// Name the professional chose to show to guests (self-asserted).
  final String hostName;
  final DateTime? expiresAt;

  static List<int> _signedBytes(
    PublicIdentity host,
    String linkId,
    String secret,
    String hostName,
    int? expiresAtSec,
  ) => concatBytes([
    domainLabel('sotto-link-v1'),
    utf8.encode(
      jsonEncode([
        b64Encode(host.signKey),
        b64Encode(host.boxKey),
        linkId,
        secret,
        hostName,
        expiresAtSec,
      ]),
    ),
  ]);

  /// Creates the URL-safe payload for a link, signed by [identity].
  static String sign(
    Sodium sodium,
    Identity identity, {
    required String linkId,
    required String secret,
    required String hostName,
    DateTime? expiresAt,
  }) {
    final exp = expiresAt == null
        ? null
        : expiresAt.millisecondsSinceEpoch ~/ 1000;
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(
        _signedBytes(identity.publicIdentity, linkId, secret, hostName, exp),
      ),
      secretKey: identity.signSecretKey,
    );
    return b64Encode(
      utf8.encode(
        jsonEncode({
          'v': version,
          'card': identity.card(sodium).toJson(),
          'lid': linkId,
          's': secret,
          'n': hostName,
          'exp': ?exp,
          'sig': b64Encode(signature),
        }),
      ),
    );
  }

  /// The full link: `<base>#g=<payload>`.
  static String url(Uri base, String payload) =>
      '${Uri(scheme: base.scheme, host: base.host, port: base.hasPort ? base.port : null, path: base.path.isEmpty ? '/' : base.path)}#$fragmentKey=$payload';

  /// Extracts the payload from a link (`…#g=<payload>`) or a bare payload.
  static String payloadOf(String input) {
    final text = input.trim();
    final hash = text.indexOf('#');
    final fragment = hash >= 0 ? text.substring(hash + 1) : text;
    for (final part in fragment.split('&')) {
      if (part.startsWith('$fragmentKey=')) return part.substring(2);
    }
    return fragment;
  }

  /// Verifies a link payload. Throws [GuestLinkException].
  static GuestLink parse(
    Sodium sodium,
    String payload, {
    DateTime Function()? clock,
  }) {
    final Map<String, dynamic> json;
    final PublicIdentity host;
    final String linkId, secret, hostName;
    final int? exp;
    final List<int> signature;
    try {
      json =
          jsonDecode(utf8.decode(b64Decode(payload))) as Map<String, dynamic>;
      if (json['v'] != version) throw const FormatException();
      host = IdentityCard.verify(sodium, json['card']);
      linkId = json['lid'] as String;
      secret = json['s'] as String;
      hostName = json['n'] as String;
      exp = json['exp'] as int?;
      signature = b64Decode(json['sig'] as String);
      if (linkId.isEmpty || secret.isEmpty || signature.length != 64) {
        throw const FormatException();
      }
    } catch (_) {
      throw const GuestLinkException(GuestLinkProblem.malformed);
    }
    final valid = sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(
        _signedBytes(host, linkId, secret, hostName, exp),
      ),
      signature: Uint8List.fromList(signature),
      publicKey: host.signKey,
    );
    if (!valid) throw const GuestLinkException(GuestLinkProblem.badSignature);
    final expiresAt = exp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    if (expiresAt != null && !(clock ?? DateTime.now)().isBefore(expiresAt)) {
      throw const GuestLinkException(GuestLinkProblem.expired);
    }
    return GuestLink(
      host: host,
      linkId: linkId,
      secret: secret,
      hostName: hostName,
      expiresAt: expiresAt,
    );
  }
}

enum GuestLinkKind { personal, oneTime }

/// A link as the professional's app remembers it (stored on the device only).
class GuestLinkRecord {
  GuestLinkRecord({
    required this.id,
    required this.secret,
    required this.kind,
    required this.createdAt,
    this.expiresAt,
    this.revoked = false,
    this.used = false,
  });

  final String id;
  final String secret;
  final GuestLinkKind kind;
  final DateTime createdAt;
  final DateTime? expiresAt;
  bool revoked;
  bool used;

  bool isUsable(DateTime now) =>
      !revoked && !used && (expiresAt == null || now.isBefore(expiresAt!));

  Map<String, Object?> toJson() => {
    'id': id,
    'secret': secret,
    'kind': kind.name,
    'created': createdAt.millisecondsSinceEpoch,
    'expires': expiresAt?.millisecondsSinceEpoch,
    'revoked': revoked,
    'used': used,
  };

  static GuestLinkRecord fromJson(Map<String, dynamic> json) => GuestLinkRecord(
    id: json['id'] as String,
    secret: json['secret'] as String,
    kind: GuestLinkKind.values.byName(json['kind'] as String),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      json['created'] as int,
      isUtc: true,
    ),
    expiresAt: json['expires'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            json['expires'] as int,
            isUtc: true,
          ),
    revoked: json['revoked'] as bool? ?? false,
    used: json['used'] as bool? ?? false,
  );
}

/// Result of checking a knock's link credentials.
enum KnockCheck { ok, unknown, revoked, expired, used }

/// The professional's guest links, kept in the device's secret store.
class GuestLinkStore {
  GuestLinkStore(this._sodium, this._secrets, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const String storageKey = 'sotto.guest_links.v1';
  static const Duration oneTimeValidity = Duration(days: 7);

  final Sodium _sodium;
  final SecretStore _secrets;
  final DateTime Function() _clock;
  final List<GuestLinkRecord> _links = [];

  List<GuestLinkRecord> get links => List.unmodifiable(_links);

  /// The current (not revoked) personal link, if any.
  GuestLinkRecord? get personal => _links
      .where((l) => l.kind == GuestLinkKind.personal && !l.revoked)
      .firstOrNull;

  /// One-time links that can still be used.
  List<GuestLinkRecord> get activeOneTime => _links
      .where((l) => l.kind == GuestLinkKind.oneTime && l.isUsable(_clock()))
      .toList();

  Future<void> load() async {
    final stored = await _secrets.read(storageKey);
    _links.clear();
    if (stored == null) return;
    try {
      final list = jsonDecode(stored) as List<dynamic>;
      _links.addAll(
        list.map((e) => GuestLinkRecord.fromJson(e as Map<String, dynamic>)),
      );
    } catch (_) {
      // Corrupt entry: start over rather than accept unknown knocks.
    }
  }

  Future<void> _save() async {
    // Forget links that can never be used again after a week.
    final cutoff = _clock().subtract(const Duration(days: 7));
    _links.removeWhere(
      (l) =>
          (l.revoked || l.used || (l.expiresAt?.isBefore(_clock()) ?? false)) &&
          l.createdAt.isBefore(cutoff),
    );
    await _secrets.write(
      storageKey,
      jsonEncode([for (final l in _links) l.toJson()]),
    );
  }

  String _random() => b64Encode(_sodium.randombytes.buf(16));

  /// Returns the personal link, creating one if needed.
  Future<GuestLinkRecord> ensurePersonal() async =>
      personal ?? await rotatePersonal();

  /// Revokes the current personal link and creates a new one.
  Future<GuestLinkRecord> rotatePersonal() async {
    for (final link in _links) {
      if (link.kind == GuestLinkKind.personal) link.revoked = true;
    }
    final link = GuestLinkRecord(
      id: _random(),
      secret: _random(),
      kind: GuestLinkKind.personal,
      createdAt: _clock().toUtc(),
    );
    _links.add(link);
    await _save();
    return link;
  }

  Future<GuestLinkRecord> createOneTime({
    Duration validFor = oneTimeValidity,
  }) async {
    final now = _clock().toUtc();
    final link = GuestLinkRecord(
      id: _random(),
      secret: _random(),
      kind: GuestLinkKind.oneTime,
      createdAt: now,
      expiresAt: now.add(validFor),
    );
    _links.add(link);
    await _save();
    return link;
  }

  Future<void> revoke(String id) async {
    for (final link in _links) {
      if (link.id == id) link.revoked = true;
    }
    await _save();
  }

  KnockCheck check(String linkId, String secret) {
    final link = _links.where((l) => l.id == linkId).firstOrNull;
    if (link == null || !_constantTimeEquals(link.secret, secret)) {
      return KnockCheck.unknown;
    }
    if (link.revoked) return KnockCheck.revoked;
    if (link.used) return KnockCheck.used;
    if (link.expiresAt != null && !_clock().isBefore(link.expiresAt!)) {
      return KnockCheck.expired;
    }
    return KnockCheck.ok;
  }

  /// One-time links are used up when their guest is admitted.
  Future<void> markAdmitted(String linkId) async {
    final link = _links.where((l) => l.id == linkId).firstOrNull;
    if (link?.kind == GuestLinkKind.oneTime) {
      link!.used = true;
      await _save();
    }
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
