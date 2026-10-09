import 'chat_frames.dart';

/// What a chat needs done after an envelope arrives, or after time passes.
/// The caller carries these out: sending envelopes, starting connections.
sealed class ChatAction {
  const ChatAction();
}

/// Send an encrypted envelope of [type] to the contact [to].
final class SendEnvelope extends ChatAction {
  const SendEnvelope({
    required this.to,
    required this.type,
    required this.body,
    this.callId,
  });

  final String to;
  final String type;
  final Map<String, Object?> body;
  final String? callId;
}

/// The chat session is agreed and its connection can be set up. The
/// [offerer] makes the offer; the other device waits for it.
final class SessionReady extends ChatAction {
  const SessionReady({
    required this.contact,
    required this.sessionId,
    required this.offerer,
    required this.tag,
  });

  final String contact;
  final String sessionId;
  final bool offerer;

  /// The tag of the device this session belongs to. Offers and answers
  /// carry it, so other devices of the contact ignore them.
  final String tag;
}

/// Opening the chat failed: [reason] is 'declined', 'not-contact' or
/// 'no-answer' (nobody's Sotto is open).
final class OpenFailed extends ChatAction {
  const OpenFailed({required this.contact, required this.reason});

  final String contact;
  final String reason;
}

/// Forget this session: another device won, or the chat was closed.
final class DropSession extends ChatAction {
  const DropSession({required this.contact, required this.sessionId});

  final String contact;
  final String sessionId;
}

/// A connection message (`chat.offer`, `chat.answer` or `chat.ice`) for an
/// active session, to be applied to its connection.
final class DeliverSignal extends ChatAction {
  const DeliverSignal({
    required this.contact,
    required this.sessionId,
    required this.type,
    required this.body,
  });

  final String contact;
  final String sessionId;
  final String type;
  final Map<String, dynamic> body;
}

/// The set-up of chats between this device and its contacts, as envelopes
/// (`docs/MESSAGING_PLAN.md`, "How a chat session is set up").
///
/// A chat is opened by one device. Every logged-in device of the contact
/// answers with its own tag; the first answer wins, the opener says so with
/// `chat.taken`, and the other devices drop their answers. Offers and
/// candidates carry the winning tag, so no other device acts on them.
///
/// When both people open a chat at the same moment, the side with the lower
/// Sotto ID keeps its own invitation and the other side answers it.
///
/// Pure logic: nothing here sends or connects. Give it envelopes with
/// [handle] and the time with [tick].
class ChatSignalling {
  ChatSignalling({
    required this.myId,
    required this.isContact,
    String Function()? newId,
    this.openTimeout = const Duration(seconds: 20),
    this.answerTimeout = const Duration(seconds: 20),
  }) : _newId = newId ?? ChatFrames.newId;

  /// This device's Sotto ID.
  final String myId;

  /// Whether [contactId] is a contact. Only contacts can open a chat.
  final bool Function(String contactId) isContact;

  /// How long an opened chat waits for an answer before it fails.
  final Duration openTimeout;

  /// How long an answering device waits for the opener's decision.
  final Duration answerTimeout;

  final String Function() _newId;

  final _openers = <String, _Opener>{}; // by contact
  final _answerers = <String, _Answerer>{}; // by session id
  final _active = <String, _Active>{}; // by session id

  /// Whether this device is waiting for an answer from [contact].
  bool isOpening(String contact) => _openers.containsKey(contact);

  /// Opens a chat with [contact].
  List<ChatAction> open(String contact, DateTime now) {
    if (_openers.containsKey(contact)) return const [];
    final sessionId = _newId();
    _openers[contact] = _Opener(sessionId: sessionId, startedAt: now);
    return [
      SendEnvelope(
        to: contact,
        type: 'chat.open',
        body: const {},
        callId: sessionId,
      ),
    ];
  }

  /// Ends an active session from this side.
  List<ChatAction> close(String sessionId) {
    final active = _active.remove(sessionId);
    if (active == null) return const [];
    return [
      SendEnvelope(
        to: active.contact,
        type: 'chat.close',
        body: const {},
        callId: sessionId,
      ),
    ];
  }

  /// Handles one chat envelope from [from], whose sender is authenticated.
  /// Other types, and anything out of order, are ignored.
  List<ChatAction> handle({
    required String from,
    required String type,
    required Map<String, dynamic> body,
    required String? callId,
    required DateTime now,
  }) {
    final sessionId = callId;
    if (sessionId == null || !ChatFrames.isId(sessionId)) return const [];
    return switch (type) {
      'chat.open' => _onOpen(from, sessionId, now),
      'chat.accept' => _onAccept(from, sessionId, body),
      'chat.decline' => _onDecline(from, sessionId, body),
      'chat.taken' => _onTaken(from, sessionId, body),
      'chat.offer' ||
      'chat.answer' ||
      'chat.ice' => _onSignal(from, sessionId, type, body),
      'chat.close' => _onClose(from, sessionId),
      _ => const [],
    };
  }

  /// Times out chats that nobody answered, and answers nobody decided on.
  List<ChatAction> tick(DateTime now) {
    final actions = <ChatAction>[];
    _openers.removeWhere((contact, opener) {
      if (now.difference(opener.startedAt) < openTimeout) return false;
      actions.add(OpenFailed(contact: contact, reason: 'no-answer'));
      return true;
    });
    _answerers.removeWhere((sessionId, answerer) {
      if (now.difference(answerer.acceptedAt) < answerTimeout) return false;
      actions.add(DropSession(contact: answerer.contact, sessionId: sessionId));
      return true;
    });
    return actions;
  }

  List<ChatAction> _onOpen(String from, String sessionId, DateTime now) {
    if (!isContact(from)) {
      return [
        SendEnvelope(
          to: from,
          type: 'chat.decline',
          body: const {'reason': 'not-contact'},
          callId: sessionId,
        ),
      ];
    }
    if (_openers.containsKey(from)) {
      // Both opened at once. The lower ID keeps its own invitation.
      if (myId.compareTo(from) < 0) return const [];
      _openers.remove(from);
    }
    final tag = _newId();
    _answerers[sessionId] = _Answerer(contact: from, tag: tag, acceptedAt: now);
    return [
      SendEnvelope(
        to: from,
        type: 'chat.accept',
        body: {'tag': tag},
        callId: sessionId,
      ),
    ];
  }

  List<ChatAction> _onAccept(
    String from,
    String sessionId,
    Map<String, dynamic> body,
  ) {
    final opener = _openers[from];
    final tag = body['tag'];
    // Only the first answer to this session counts: the opener is removed.
    if (opener == null ||
        opener.sessionId != sessionId ||
        !ChatFrames.isId(tag)) {
      return const [];
    }
    _openers.remove(from);
    _active[sessionId] = _Active(contact: from, tag: tag as String);
    return [
      SendEnvelope(
        to: from,
        type: 'chat.taken',
        body: {'tag': tag},
        callId: sessionId,
      ),
      SessionReady(
        contact: from,
        sessionId: sessionId,
        offerer: true,
        tag: tag,
      ),
    ];
  }

  List<ChatAction> _onDecline(
    String from,
    String sessionId,
    Map<String, dynamic> body,
  ) {
    final opener = _openers[from];
    if (opener == null || opener.sessionId != sessionId) return const [];
    _openers.remove(from);
    return [
      OpenFailed(
        contact: from,
        reason: body['reason'] == 'not-contact' ? 'not-contact' : 'declined',
      ),
    ];
  }

  List<ChatAction> _onTaken(
    String from,
    String sessionId,
    Map<String, dynamic> body,
  ) {
    final answerer = _answerers[sessionId];
    if (answerer == null || answerer.contact != from) return const [];
    _answerers.remove(sessionId);
    if (body['tag'] != answerer.tag) {
      return [DropSession(contact: from, sessionId: sessionId)];
    }
    _active[sessionId] = _Active(contact: from, tag: answerer.tag);
    return [
      SessionReady(
        contact: from,
        sessionId: sessionId,
        offerer: false,
        tag: answerer.tag,
      ),
    ];
  }

  List<ChatAction> _onSignal(
    String from,
    String sessionId,
    String type,
    Map<String, dynamic> body,
  ) {
    final tag = body['tag'];
    final answerer = _answerers[sessionId];
    // The offer only goes to the device that won. If it arrives before
    // `chat.taken`, it still proves this device won.
    if (type == 'chat.offer' &&
        answerer != null &&
        answerer.contact == from &&
        tag == answerer.tag) {
      _answerers.remove(sessionId);
      _active[sessionId] = _Active(contact: from, tag: answerer.tag);
      return [
        SessionReady(
          contact: from,
          sessionId: sessionId,
          offerer: false,
          tag: answerer.tag,
        ),
        DeliverSignal(
          contact: from,
          sessionId: sessionId,
          type: type,
          body: body,
        ),
      ];
    }
    final active = _active[sessionId];
    if (active == null || active.contact != from || tag != active.tag) {
      return const [];
    }
    return [
      DeliverSignal(
        contact: from,
        sessionId: sessionId,
        type: type,
        body: body,
      ),
    ];
  }

  List<ChatAction> _onClose(String from, String sessionId) {
    final active = _active[sessionId];
    if (active == null || active.contact != from) return const [];
    _active.remove(sessionId);
    return [DropSession(contact: from, sessionId: sessionId)];
  }
}

class _Opener {
  _Opener({required this.sessionId, required this.startedAt});

  final String sessionId;
  final DateTime startedAt;
}

class _Answerer {
  _Answerer({
    required this.contact,
    required this.tag,
    required this.acceptedAt,
  });

  final String contact;
  final String tag;
  final DateTime acceptedAt;
}

class _Active {
  _Active({required this.contact, required this.tag});

  final String contact;
  final String tag;
}
