import 'dart:convert';
import 'dart:math';

import '../crypto/encoding.dart';

/// The frames of a chat session, sent over its data channel as UTF-8 JSON
/// (`docs/MESSAGING_PLAN.md`, "Frames").
///
/// Every frame is at most [maxFrameBytes] bytes. Text is at most
/// [maxTextChars] characters after cleaning.
const int chatProtocolVersion = 1;
const int maxFrameBytes = 16 * 1024;
const int maxTextChars = 4000;

sealed class ChatFrame {
  const ChatFrame();
}

/// The first frame from each side. Other versions close the session.
final class HelloFrame extends ChatFrame {
  const HelloFrame();
}

final class MessageFrame extends ChatFrame {
  const MessageFrame({required this.id, required this.ts, required this.text});

  /// 16 random bytes, unpadded base64url.
  final String id;

  /// The sender's clock, in milliseconds since the Unix epoch.
  final int ts;

  final String text;
}

/// The receiver has stored the message with this [id] and verified it.
final class AckFrame extends ChatFrame {
  const AckFrame({required this.id});
  final String id;
}

/// Ephemeral indication of whether the sender is currently typing.
final class TypingFrame extends ChatFrame {
  const TypingFrame({required this.typing});
  final bool typing;
}

/// The receiver has viewed the messages with these [ids].
final class ReadFrame extends ChatFrame {
  const ReadFrame({required this.ids});
  final List<String> ids;
}

/// The session is ending normally.
final class ByeFrame extends ChatFrame {
  const ByeFrame();
}

/// A frame that must not be acted on. [reason] is for the diagnostic report
/// only, never for the person.
class ChatFrameException implements Exception {
  const ChatFrameException(this.reason);

  final String reason;

  @override
  String toString() => 'ChatFrameException: $reason';
}

/// Encodes and decodes chat frames, rejecting anything malformed.
abstract final class ChatFrames {
  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{22}$');

  /// Sixteen random bytes as unpadded base64url: a message or session id.
  static String newId([Random? random]) {
    final rng = random ?? Random.secure();
    return b64Encode(List<int>.generate(16, (_) => rng.nextInt(256)));
  }

  /// Removes what should never be shown: control characters (line breaks and
  /// tabs are kept) and the Unicode characters that change text direction
  /// without being seen, which can make a message read differently from how
  /// it was written. Also trims the ends.
  ///
  /// Applied to text on the way in and on the way out.
  static String cleanText(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      final control =
          (rune < 0x20 && rune != 0x0A && rune != 0x09) ||
          (rune >= 0x7F && rune <= 0x9F) ||
          (rune >= 0x202A && rune <= 0x202E) ||
          (rune >= 0x2066 && rune <= 0x2069);
      if (!control) buffer.writeCharCode(rune);
    }
    return buffer.toString().trim();
  }

  /// Encodes [frame] as the text of one data-channel message.
  static String encode(ChatFrame frame) {
    final json = switch (frame) {
      HelloFrame() => {'t': 'hello', 'v': chatProtocolVersion},
      MessageFrame(:final id, :final ts, :final text) => {
        't': 'msg',
        'id': id,
        'ts': ts,
        'text': text,
      },
      AckFrame(:final id) => {'t': 'ack', 'id': id},
      TypingFrame(:final typing) => {'t': 'typing', 'typing': typing},
      ReadFrame(:final ids) => {'t': 'read', 'ids': ids},
      ByeFrame() => {'t': 'bye'},
    };
    final text = jsonEncode(json);
    if (utf8.encode(text).length > maxFrameBytes) {
      throw const ChatFrameException('too-large');
    }
    return text;
  }

  /// Decodes one data-channel message. Throws [ChatFrameException] for
  /// anything not exactly in the format.
  static ChatFrame decode(String text) {
    if (utf8.encode(text).length > maxFrameBytes) {
      throw const ChatFrameException('too-large');
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const ChatFrameException('malformed');
    }
    if (json is! Map<String, dynamic>) {
      throw const ChatFrameException('malformed');
    }
    switch (json['t']) {
      case 'hello':
        if (json['v'] != chatProtocolVersion) {
          throw const ChatFrameException('version');
        }
        return const HelloFrame();
      case 'msg':
        final id = _id(json['id']);
        final ts = json['ts'];
        final raw = json['text'];
        if (ts is! int || ts <= 0 || raw is! String) {
          throw const ChatFrameException('malformed');
        }
        final cleaned = cleanText(raw);
        if (cleaned.runes.length > maxTextChars) {
          throw const ChatFrameException('too-long');
        }
        return MessageFrame(id: id, ts: ts, text: cleaned);
      case 'ack':
        return AckFrame(id: _id(json['id']));
      case 'typing':
        final typing = json['typing'];
        if (typing is! bool) throw const ChatFrameException('malformed');
        return TypingFrame(typing: typing);
      case 'read':
        final rawIds = json['ids'];
        if (rawIds is! List || rawIds.isEmpty) {
          throw const ChatFrameException('malformed');
        }
        final ids = <String>[];
        for (final item in rawIds) {
          ids.add(_id(item));
        }
        return ReadFrame(ids: ids);
      case 'bye':
        return const ByeFrame();
      default:
        throw const ChatFrameException('unknown');
    }
  }

  /// Whether [value] is an id made by [newId]: 16 bytes, unpadded base64url.
  static bool isId(Object? value) =>
      value is String && _idPattern.hasMatch(value);

  static String _id(Object? value) {
    if (!isId(value)) throw const ChatFrameException('malformed');
    return value as String;
  }
}
