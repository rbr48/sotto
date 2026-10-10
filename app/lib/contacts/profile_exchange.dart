import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../core/avatar_data.dart';
import '../crypto/encoding.dart';
import '../crypto/envelope.dart';
import '../crypto/identity.dart';
import 'contact_link.dart';

/// Name, organisation, and optional avatar someone shows to people who open their link.
typedef PublicProfile = ({String name, String organisation, String? avatar});

/// Why a short link could not be looked up.
class ProfileUnavailableException implements Exception {
  const ProfileUnavailableException();
  @override
  String toString() => 'ProfileUnavailableException';
}

/// Looks up the person behind a short link, which carries only their
/// signing key (their relay address), and answers such lookups.
///
/// ```
/// request = "p1." || base64url(requester's identity card)    (not secret)
/// reply   = envelope of type "profile", body {n, o?, av?}      (sealed, signed)
/// ```
/// `av` is the profile picture, a JPEG or PNG data URI; it is sent only, and
/// accepted only, when it passes [AvatarData.parse] (at most
/// [AvatarData.maxSharedLength] characters and [AvatarData.maxSide] pixels a
/// side, with bytes of the type it claims). Anyone who has the link gets it.
/// The reply is an ordinary envelope signed by the key in the link, so its
/// encryption key, name and organisation are as trustworthy as a full
/// contact link. The relay sees only that one ID asked another for its
/// card, as it sees any message between two IDs.
class ProfileExchange {
  ProfileExchange({
    required this._sodium,
    required this._identity,
    required this._codec,
    required this._send,
    PublicProfile? Function()? profile,
    DateTime Function()? clock,
  }) : _profile = profile ?? (() => null),
       _clock = clock ?? DateTime.now;

  static const String requestPrefix = 'p1.';
  static const String replyType = 'profile';

  /// At most this many answers a minute, and one per requester every
  /// [perRequesterGap], so the lookup can't be used to flood anyone.
  static const int answersPerMinute = 30;
  static const Duration perRequesterGap = Duration(seconds: 3);

  final Sodium _sodium;
  final Identity _identity;
  final EnvelopeCodec _codec;
  final void Function(String to, String body) _send;
  final PublicProfile? Function() _profile;
  final DateTime Function() _clock;

  final _waiting = <String, Completer<ContactInvite>>{};
  final _lastAnswer = <String, DateTime>{};
  final _recentAnswers = <DateTime>[];

  static bool isRequest(String body) => body.startsWith(requestPrefix);

  /// Asks the owner of [signKey] for their card, name and organisation.
  /// Throws [ProfileUnavailableException] when no answer comes in [timeout]
  /// (their Sotto is offline, or too old to answer).
  Future<ContactInvite> fetch(
    Uint8List signKey, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final id = b64Encode(signKey);
    final waiter = _waiting[id] ??= Completer<ContactInvite>();
    _send(
      id,
      '$requestPrefix${b64Encode(utf8.encode(_identity.card(_sodium).encode()))}',
    );
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      throw const ProfileUnavailableException();
    } finally {
      if (identical(_waiting[id], waiter)) _waiting.remove(id);
    }
  }

  /// Answers a lookup from [from] (as authenticated by the relay).
  void answer(String from, String body) {
    final profile = _profile();
    if (profile == null || !isRequest(body)) return;
    final PublicIdentity requester;
    try {
      requester = IdentityCard.verify(
        _sodium,
        utf8.decode(b64Decode(body.substring(requestPrefix.length))),
      );
    } catch (_) {
      return;
    }
    // The card must belong to whoever sent it (the reply is sealed to it).
    if (requester.id != from || requester.id == _identity.id) return;
    final now = _clock();
    final last = _lastAnswer[from];
    if (last != null && now.difference(last) < perRequesterGap) return;
    _recentAnswers.removeWhere(
      (t) => now.difference(t) >= const Duration(minutes: 1),
    );
    if (_recentAnswers.length >= answersPerMinute) return;
    _recentAnswers.add(now);
    _lastAnswer[from] = now;
    if (_lastAnswer.length > 1000) _lastAnswer.clear();
    final name = profile.name.trim();
    final organisation = profile.organisation.trim();
    final reply = <String, Object>{
      'n': name.isEmpty
          ? 'Sotto user'
          : name.substring(0, name.length.clamp(0, 80)),
      if (organisation.isNotEmpty)
        'o': organisation.substring(0, organisation.length.clamp(0, 80)),
    };
    final avatar = AvatarData.sanitize(profile.avatar?.trim());

    String? sealed;
    if (avatar != null) {
      try {
        sealed = _codec.seal(
          recipient: requester,
          type: replyType,
          body: {...reply, 'av': avatar},
        );
      } catch (_) {
        sealed = null;
      }
    }
    try {
      // Without the picture if it could not be sealed, so the lookup is
      // still answered.
      sealed ??= _codec.seal(
        recipient: requester,
        type: replyType,
        body: reply,
      );
      _send(from, sealed);
    } catch (_) {
      // Not even the name could be sealed: no answer.
    }
  }

  /// Takes a verified reply to one of our lookups; false if [message] is
  /// not one.
  bool handleReply(OpenedMessage message) {
    if (message.type != replyType) return false;
    final waiter = _waiting[message.sender.id];
    final name = message.body['n'];
    final organisation = message.body['o'];
    // A picture that is not a small, well-formed JPEG or PNG is dropped;
    // the name and organisation are still taken.
    final rawAvatar = message.body['av'];
    final avatar = rawAvatar is String ? AvatarData.sanitize(rawAvatar) : null;
    if (waiter == null ||
        waiter.isCompleted ||
        name is! String ||
        name.isEmpty ||
        name.length > ContactLink.maxNameLength ||
        (organisation != null &&
            (organisation is! String ||
                organisation.length > ContactLink.maxNameLength))) {
      return true;
    }
    waiter.complete(
      ContactInvite(
        identity: message.sender,
        name: name,
        organisation: (organisation as String?)?.isEmpty ?? true
            ? null
            : organisation,
        avatar: avatar,
      ),
    );
    return true;
  }
}
