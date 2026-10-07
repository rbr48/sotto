import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import 'encoding.dart';
import 'identity.dart';
import 'replay_guard.dart';

/// Why an envelope was rejected. Every failure to open an envelope throws an
/// [EnvelopeException]; nothing else escapes [EnvelopeCodec.open].
enum EnvelopeError {
  /// Not base64url, or too short to be a sealed box.
  malformed,

  /// Could not be decrypted with our key (tampered, or not for us).
  undecryptable,

  /// Decrypted, but the inner message is not valid.
  invalidMessage,

  /// Addressed to someone else (a signed message re-sealed to us).
  wrongRecipient,

  /// The sender's signature does not verify.
  badSignature,

  /// Signed by someone other than the expected sender.
  unexpectedSender,

  /// Timestamp outside the accepted window.
  expired,

  /// Already received.
  replayed,

  /// Message to send is larger than [EnvelopeCodec.maxInnerBytes].
  tooLarge,
}

class EnvelopeException implements Exception {
  const EnvelopeException(this.error);
  final EnvelopeError error;
  @override
  String toString() => 'EnvelopeException(${error.name})';
}

/// A verified message taken out of an envelope.
class OpenedMessage {
  const OpenedMessage({
    required this.sender,
    required this.type,
    required this.body,
    required this.sentAt,
    this.callId,
  });

  /// The sender's verified identity; reply to [PublicIdentity.boxKey].
  final PublicIdentity sender;
  final String type;
  final Map<String, dynamic> body;
  final DateTime sentAt;
  final String? callId;
}

/// Seals and opens end-to-end encrypted Sotto messages.
///
/// Format (see docs/PROTOCOL.md):
/// ```
/// inner     = UTF-8 JSON {v, from, fromBox, to, ts, n, type, callId?, body}
/// signature = Ed25519("sotto-msg-v1\0" || inner)       // sender's signing key
/// envelope  = base64url(crypto_box_seal(signature || inner, recipient.boxKey))
/// ```
/// The signature covers the recipient (`to`), so a message can't be
/// re-addressed; the timestamp and random nonce `n` stop replays.
class EnvelopeCodec {
  EnvelopeCodec(
    this._sodium,
    this._identity, {
    DateTime Function()? clock,
    this.maxAge = const Duration(minutes: 2),
    this.maxClockSkew = const Duration(minutes: 2),
    ReplayGuard? replayGuard,
  }) : _clock = clock ?? DateTime.now,
       _replayGuard =
           replayGuard ??
           ReplayGuard(ttl: maxAge + maxClockSkew + const Duration(seconds: 1));

  static const int version = 1;
  static const int maxInnerBytes = 48 * 1024;
  static const int _signatureBytes = 64;
  static const int _nonceBytes = 16;

  final Sodium _sodium;
  final Identity _identity;
  final DateTime Function() _clock;
  final ReplayGuard _replayGuard;

  /// Messages older than this are rejected.
  final Duration maxAge;

  /// Messages dated this far in the future are still accepted.
  final Duration maxClockSkew;

  /// Encrypts [body] for [recipient]. Returns the envelope text.
  String seal({
    required PublicIdentity recipient,
    required String type,
    required Map<String, Object?> body,
    String? callId,
  }) {
    final inner = utf8.encode(
      jsonEncode({
        'v': version,
        'from': _identity.id,
        'fromBox': b64Encode(_identity.publicIdentity.boxKey),
        'to': recipient.id,
        'ts': _clock().millisecondsSinceEpoch,
        'n': b64Encode(_sodium.randombytes.buf(_nonceBytes)),
        'type': type,
        'callId': ?callId,
        'body': body,
      }),
    );
    if (inner.length > maxInnerBytes) {
      throw const EnvelopeException(EnvelopeError.tooLarge);
    }
    final signature = _sodium.crypto.sign.detached(
      message: _signedBytes(inner),
      secretKey: _identity.signSecretKey,
    );
    return b64Encode(
      _sodium.crypto.box.seal(
        message: concatBytes([signature, inner]),
        publicKey: recipient.boxKey,
      ),
    );
  }

  /// Decrypts and verifies an envelope addressed to us.
  ///
  /// If [expectedSender] is given (for example the relay-authenticated sender
  /// address, or the peer of an ongoing call), the message must be signed by
  /// that identity id.
  OpenedMessage open(String envelope, {String? expectedSender}) {
    final Uint8List sealed;
    try {
      sealed = b64Decode(envelope);
    } on FormatException {
      throw const EnvelopeException(EnvelopeError.malformed);
    }
    if (sealed.length < _sodium.crypto.box.sealBytes + _signatureBytes + 2) {
      throw const EnvelopeException(EnvelopeError.malformed);
    }

    final Uint8List plain;
    try {
      plain = _sodium.crypto.box.sealOpen(
        cipherText: sealed,
        publicKey: _identity.publicIdentity.boxKey,
        secretKey: _identity.boxSecretKey,
      );
    } catch (_) {
      throw const EnvelopeException(EnvelopeError.undecryptable);
    }

    final signature = Uint8List.sublistView(plain, 0, _signatureBytes);
    final inner = Uint8List.sublistView(plain, _signatureBytes);
    final message = _parseInner(inner);

    if (message.to != _identity.id) {
      throw const EnvelopeException(EnvelopeError.wrongRecipient);
    }
    if (!_sodium.crypto.sign.verifyDetached(
      message: _signedBytes(inner),
      signature: signature,
      publicKey: message.sender.signKey,
    )) {
      throw const EnvelopeException(EnvelopeError.badSignature);
    }
    if (expectedSender != null && message.sender.id != expectedSender) {
      throw const EnvelopeException(EnvelopeError.unexpectedSender);
    }
    final now = _clock();
    if (message.sentAt.isBefore(now.subtract(maxAge)) ||
        message.sentAt.isAfter(now.add(maxClockSkew))) {
      throw const EnvelopeException(EnvelopeError.expired);
    }
    if (!_replayGuard.checkAndRecord(
      '${message.sender.id}/${message.nonce}',
      now,
    )) {
      throw const EnvelopeException(EnvelopeError.replayed);
    }
    return OpenedMessage(
      sender: message.sender,
      type: message.type,
      body: message.body,
      sentAt: message.sentAt,
      callId: message.callId,
    );
  }

  static Uint8List _signedBytes(List<int> inner) =>
      concatBytes([domainLabel('sotto-msg-v1'), inner]);

  static _Inner _parseInner(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic> || json['v'] != version) {
        throw const FormatException();
      }
      final nonce = json['n'] as String;
      if (b64Decode(nonce).length != _nonceBytes) throw const FormatException();
      final type = json['type'] as String;
      if (type.isEmpty) throw const FormatException();
      return _Inner(
        sender: PublicIdentity(
          signKey: b64Decode(json['from'] as String),
          boxKey: b64Decode(json['fromBox'] as String),
        ),
        to: json['to'] as String,
        sentAt: DateTime.fromMillisecondsSinceEpoch(
          json['ts'] as int,
          isUtc: true,
        ),
        nonce: nonce,
        type: type,
        callId: json['callId'] as String?,
        body: json['body'] as Map<String, dynamic>,
      );
    } catch (_) {
      throw const EnvelopeException(EnvelopeError.invalidMessage);
    }
  }
}

class _Inner {
  const _Inner({
    required this.sender,
    required this.to,
    required this.sentAt,
    required this.nonce,
    required this.type,
    required this.body,
    this.callId,
  });

  final PublicIdentity sender;
  final String to;
  final DateTime sentAt;
  final String nonce;
  final String type;
  final Map<String, dynamic> body;
  final String? callId;
}
