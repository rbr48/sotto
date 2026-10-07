import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import 'encoding.dart';

/// Thrown when an identity card or public key is invalid.
class InvalidIdentityException implements Exception {
  const InvalidIdentityException(this.message);
  final String message;
  @override
  String toString() => 'InvalidIdentityException: $message';
}

/// The public half of an identity: an Ed25519 signing key (which is also the
/// user's address, [id]) and an X25519 key that others encrypt to.
class PublicIdentity {
  PublicIdentity({required this.signKey, required this.boxKey}) {
    if (signKey.length != 32 || boxKey.length != 32) {
      throw const InvalidIdentityException('public keys must be 32 bytes');
    }
  }

  final Uint8List signKey;
  final Uint8List boxKey;

  /// The user's address on the relay: base64url of [signKey].
  String get id => b64Encode(signKey);

  @override
  bool operator ==(Object other) =>
      other is PublicIdentity &&
      bytesEqual(other.signKey, signKey) &&
      bytesEqual(other.boxKey, boxKey);

  @override
  int get hashCode => Object.hash(id, b64Encode(boxKey));
}

/// A full identity with secret keys.
///
/// Both key pairs are derived from one 32-byte master secret with
/// `crypto_kdf` (context `sottoid1`; subkey 1 = Ed25519 seed, subkey 2 =
/// X25519 seed), so a backup only has to hold the master secret.
class Identity {
  Identity._(this._sign, this._box);

  static const String kdfContext = 'sottoid1';

  final KeyPair _sign;
  final KeyPair _box;

  late final PublicIdentity publicIdentity = PublicIdentity(
    signKey: _sign.publicKey,
    boxKey: _box.publicKey,
  );

  String get id => publicIdentity.id;
  SecureKey get signSecretKey => _sign.secretKey;
  SecureKey get boxSecretKey => _box.secretKey;

  /// Derives the identity from a master secret (deterministic).
  factory Identity.fromMasterSecret(Sodium sodium, SecureKey master) {
    SecureKey derive(int subkeyId) => sodium.crypto.kdf.deriveFromKey(
      masterKey: master,
      context: kdfContext,
      subkeyId: BigInt.from(subkeyId),
      subkeyLen: 32,
    );
    final signSeed = derive(1);
    final boxSeed = derive(2);
    try {
      return Identity._(
        sodium.crypto.sign.seedKeyPair(signSeed),
        sodium.crypto.box.seedKeyPair(boxSeed),
      );
    } finally {
      signSeed.dispose();
      boxSeed.dispose();
    }
  }

  /// A fresh random identity, e.g. a guest's temporary identity for one call.
  factory Identity.generate(Sodium sodium) {
    final master = sodium.crypto.kdf.keygen();
    try {
      return Identity.fromMasterSecret(sodium, master);
    } finally {
      master.dispose();
    }
  }

  /// A signed statement binding this identity's encryption key to its
  /// signing key, safe to send over an untrusted channel.
  IdentityCard card(Sodium sodium) => IdentityCard(
    identity: publicIdentity,
    signature: sodium.crypto.sign.detached(
      message: IdentityCard._signedBytes(publicIdentity),
      secretKey: _sign.secretKey,
    ),
  );

  void dispose() {
    _sign.secretKey.dispose();
    _box.secretKey.dispose();
  }
}

/// `{"v":1,"sign":…,"box":…,"sig":…}`: a public identity plus an Ed25519
/// signature over `"sotto-card-v1\0" || sign || box`.
///
/// A card proves that the owner of the signing key chose this encryption key.
/// It does not prove who the person is: that is what safety numbers are for.
class IdentityCard {
  IdentityCard({required this.identity, required this.signature});

  static const int version = 1;

  final PublicIdentity identity;
  final Uint8List signature;

  static Uint8List _signedBytes(PublicIdentity identity) => concatBytes([
    domainLabel('sotto-card-v1'),
    identity.signKey,
    identity.boxKey,
  ]);

  Map<String, Object> toJson() => {
    'v': version,
    'sign': b64Encode(identity.signKey),
    'box': b64Encode(identity.boxKey),
    'sig': b64Encode(signature),
  };

  String encode() => jsonEncode(toJson());

  /// Parses and verifies a card. Throws [InvalidIdentityException].
  static PublicIdentity verify(Sodium sodium, Object? json) {
    if (json is String) {
      try {
        json = jsonDecode(json);
      } on FormatException {
        throw const InvalidIdentityException('card is not JSON');
      }
    }
    if (json is! Map<String, dynamic> || json['v'] != version) {
      throw const InvalidIdentityException('unsupported card');
    }
    final PublicIdentity identity;
    final Uint8List signature;
    try {
      identity = PublicIdentity(
        signKey: b64Decode(json['sign'] as String),
        boxKey: b64Decode(json['box'] as String),
      );
      signature = b64Decode(json['sig'] as String);
    } on InvalidIdentityException {
      rethrow;
    } catch (_) {
      throw const InvalidIdentityException('malformed card');
    }
    if (signature.length != 64 ||
        !sodium.crypto.sign.verifyDetached(
          message: _signedBytes(identity),
          signature: signature,
          publicKey: identity.signKey,
        )) {
      throw const InvalidIdentityException('bad card signature');
    }
    return identity;
  }
}
