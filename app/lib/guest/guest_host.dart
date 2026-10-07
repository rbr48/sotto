import 'dart:async';

import 'package:flutter/foundation.dart';

import '../crypto/envelope.dart';
import '../crypto/identity.dart';
import 'guest_link.dart';

/// Sends an end-to-end encrypted non-call message (`guest.*`) to [to].
typedef GuestMessageSender = void Function(
  PublicIdentity to,
  String type,
  Map<String, Object?> body,
);

/// A guest knocking on one of the professional's links.
class WaitingGuest {
  WaitingGuest({
    required this.knockId,
    required this.guest,
    required this.name,
    required this.video,
    required this.linkId,
    required this.since,
    required this.lastSeen,
  });

  final String knockId;
  final PublicIdentity guest;

  /// Typed by the guest; not verified.
  final String name;
  final bool video;
  final String linkId;
  final DateTime since;
  DateTime lastSeen;
}

/// The professional's side of guest links: checks knocks against the link
/// store and keeps the waiting room. Admitting a guest is done by calling
/// them ([onAdmit]); their page answers automatically.
///
/// Messages (inside envelopes):
/// - guest → host `guest.knock` `{knock, link, secret, name, video}` (repeated
///   while waiting), `guest.leave` `{knock}`
/// - host → guest `guest.declined` `{knock, reason}`, `guest.message`
///   `{knock, text}`
class GuestHost extends ChangeNotifier {
  GuestHost({
    required this.links,
    required this.send,
    required this.onAdmit,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _sweeper = Timer.periodic(const Duration(seconds: 15), (_) => _expire());
  }

  /// A knock that isn't repeated for this long is dropped (tab closed).
  static const Duration knockTimeout = Duration(seconds: 75);
  static const int maxWaiting = 20;
  static const int maxNameLength = 60;

  final GuestLinkStore links;
  final GuestMessageSender send;
  final Future<void> Function(WaitingGuest guest) onAdmit;
  final DateTime Function() _clock;
  late final Timer _sweeper;

  final List<WaitingGuest> _waiting = [];
  List<WaitingGuest> get waiting => List.unmodifiable(_waiting);

  /// Handles `guest.*` messages. Returns false for other types.
  bool handle(OpenedMessage message) {
    switch (message.type) {
      case 'guest.knock':
        _onKnock(message);
        return true;
      case 'guest.leave':
        final knock = message.body['knock'];
        final before = _waiting.length;
        _waiting.removeWhere(
          (w) => w.knockId == knock && w.guest == message.sender,
        );
        if (_waiting.length != before) notifyListeners();
        return true;
      default:
        return false;
    }
  }

  void _onKnock(OpenedMessage message) {
    final body = message.body;
    final knockId = body['knock'];
    final linkId = body['link'];
    final secret = body['secret'];
    if (knockId is! String || knockId.isEmpty || knockId.length > 64) return;
    if (linkId is! String || secret is! String) return;

    final check = links.check(linkId, secret);
    if (check != KnockCheck.ok) {
      send(message.sender, 'guest.declined', {
        'knock': knockId,
        'reason': check.name,
      });
      return;
    }
    final now = _clock();
    final existing = _waiting
        .where((w) => w.knockId == knockId && w.guest == message.sender)
        .firstOrNull;
    if (existing != null) {
      existing.lastSeen = now;
      return;
    }
    if (_waiting.length >= maxWaiting) {
      send(message.sender, 'guest.declined', {
        'knock': knockId,
        'reason': 'full',
      });
      return;
    }
    final rawName = body['name'];
    final name = rawName is String ? rawName.trim() : '';
    _waiting.add(
      WaitingGuest(
        knockId: knockId,
        guest: message.sender,
        name: name.isEmpty
            ? 'Guest'
            : name.substring(0, name.length.clamp(0, maxNameLength)),
        video: body['video'] != false,
        linkId: linkId,
        since: now,
        lastSeen: now,
      ),
    );
    notifyListeners();
  }

  /// Starts the call with a waiting guest.
  Future<void> admit(String knockId) async {
    final guest = _take(knockId);
    if (guest == null) return;
    await links.markAdmitted(guest.linkId);
    await onAdmit(guest);
  }

  void decline(String knockId) {
    final guest = _take(knockId);
    if (guest == null) return;
    send(guest.guest, 'guest.declined', {
      'knock': knockId,
      'reason': 'declined',
    });
  }

  /// Sends a short message to a waiting guest ("I'll be with you in 5 minutes").
  void message(String knockId, String text) {
    final guest = _waiting.where((w) => w.knockId == knockId).firstOrNull;
    if (guest == null) return;
    send(guest.guest, 'guest.message', {'knock': knockId, 'text': text});
  }

  WaitingGuest? _take(String knockId) {
    final index = _waiting.indexWhere((w) => w.knockId == knockId);
    if (index < 0) return null;
    final guest = _waiting.removeAt(index);
    notifyListeners();
    return guest;
  }

  void _expire() {
    final cutoff = _clock().subtract(knockTimeout);
    final before = _waiting.length;
    _waiting.removeWhere((w) => w.lastSeen.isBefore(cutoff));
    if (_waiting.length != before) notifyListeners();
  }

  @override
  void dispose() {
    _sweeper.cancel();
    super.dispose();
  }
}
