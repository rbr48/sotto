import 'dart:async';

import 'package:flutter/foundation.dart';

import '../crypto/envelope.dart';
import 'guest_host.dart';
import 'guest_link.dart';

enum GuestVisitPhase {
  /// Checking camera and microphone, choosing a name.
  preparing,

  /// Knocked; waiting for the professional to let us in.
  waiting,

  /// Let in: the call is being set up or running (see the call state).
  admitted,

  /// The professional declined, or the link turned out to be unusable.
  declined,
}

/// The guest's side of a guest link: knocks (and keeps knocking while
/// waiting, so a professional who comes online later still sees it), shows
/// messages from the professional, and recognises the call that admits us.
class GuestVisit extends ChangeNotifier {
  GuestVisit({
    required this.link,
    required this.send,
    required this.newKnockId,
  });

  static const Duration knockInterval = Duration(seconds: 25);

  final GuestLink link;
  final GuestMessageSender send;
  final String Function() newKnockId;

  GuestVisitPhase _phase = GuestVisitPhase.preparing;
  GuestVisitPhase get phase => _phase;

  /// Why we were declined: `declined`, `revoked`, `used`, `expired`,
  /// `unknown` or `full`.
  String? _declineReason;
  String? get declineReason => _declineReason;

  String? _hostMessage;
  String? get hostMessage => _hostMessage;

  DateTime? _waitingSince;
  DateTime? get waitingSince => _waitingSince;

  String? _knockId;
  Timer? _timer;
  late Map<String, Object?> _knockBody;

  /// Knocks on the professional's door.
  void knock({required String name, required bool video}) {
    _timer?.cancel();
    _knockId = newKnockId();
    _knockBody = {
      'knock': _knockId,
      'link': link.linkId,
      'secret': link.secret,
      'name': name.trim(),
      'video': video,
    };
    _phase = GuestVisitPhase.waiting;
    _declineReason = null;
    _hostMessage = null;
    _waitingSince = DateTime.now();
    send(link.host, 'guest.knock', _knockBody);
    _timer = Timer.periodic(knockInterval, (_) {
      if (_phase == GuestVisitPhase.waiting) {
        send(link.host, 'guest.knock', _knockBody);
      }
    });
    notifyListeners();
  }

  /// Stops waiting.
  void leave() {
    if (_phase == GuestVisitPhase.waiting && _knockId != null) {
      send(link.host, 'guest.leave', {'knock': _knockId});
    }
    _timer?.cancel();
    _phase = GuestVisitPhase.preparing;
    notifyListeners();
  }

  /// Ready to knock again after a call or a decline.
  void reset() {
    _timer?.cancel();
    _phase = GuestVisitPhase.preparing;
    _knockId = null;
    notifyListeners();
  }

  /// Handles messages from the professional. Returns false for other types.
  bool handle(OpenedMessage message) {
    if (message.sender != link.host) return false;
    final knock = message.body['knock'];
    switch (message.type) {
      case 'guest.declined'
          when knock == _knockId && _phase == GuestVisitPhase.waiting:
        _timer?.cancel();
        final reason = message.body['reason'];
        _declineReason = reason is String ? reason : 'declined';
        _phase = GuestVisitPhase.declined;
        notifyListeners();
        return true;
      case 'guest.message' when knock == _knockId:
        final text = message.body['text'];
        if (text is String) {
          _hostMessage = text.length > 200 ? text.substring(0, 200) : text;
          notifyListeners();
        }
        return true;
      default:
        return message.type.startsWith('guest.');
    }
  }

  /// Whether an incoming call is the professional admitting us; such calls
  /// are answered immediately.
  bool isAdmission(OpenedMessage invite) {
    final admitted =
        _phase == GuestVisitPhase.waiting &&
        invite.sender == link.host &&
        invite.body['knock'] == _knockId;
    if (admitted) {
      _timer?.cancel();
      _phase = GuestVisitPhase.admitted;
      notifyListeners();
    }
    return admitted;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
