import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/encoding.dart';

/// The frames of a chat session, sent over its data channel as UTF-8 JSON
/// (`docs/MESSAGING_PLAN.md`, "Frames") or binary chunks (`docs/FILE_SHARING_PLAN.md`).
///
/// Every frame is at most [maxFrameBytes] bytes. Text is at most
/// [maxTextChars] characters after cleaning.
const int chatProtocolVersion = 1;
const int maxFrameBytes = 16 * 1024;
const int maxTextChars = 4000;
const int fileChunkSize = 16 * 1024; // 16 KiB binary chunks
const int maxFileSizeNative = 100 * 1024 * 1024; // 100 MB
const int maxFileSizeWeb = 25 * 1024 * 1024; // 25 MB

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

/// Offer to send a file or photo directly to the peer.
final class FileOfferFrame extends ChatFrame {
  const FileOfferFrame({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.sha256,
    required this.chunks,
  });

  /// 16 random bytes, unpadded base64url.
  final String id;
  final String name;
  final int size;
  final String mime;
  final String sha256;
  final int chunks;
}

/// The receiver accepts the offered file transfer.
final class FileAcceptFrame extends ChatFrame {
  const FileAcceptFrame({required this.id});
  final String id;
}

/// The receiver declines the offered file transfer.
final class FileDeclineFrame extends ChatFrame {
  const FileDeclineFrame({required this.id});
  final String id;
}

/// The sender has transmitted all binary chunks.
final class FileDoneFrame extends ChatFrame {
  const FileDoneFrame({required this.id});
  final String id;
}

/// The receiver has verified the SHA-256 hash and stored the file.
final class FileAckFrame extends ChatFrame {
  const FileAckFrame({required this.id});
  final String id;
}

/// Either side cancels the file transfer in progress.
final class FileCancelFrame extends ChatFrame {
  const FileCancelFrame({required this.id, this.reason});
  final String id;
  final String? reason;
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
      FileOfferFrame(
        :final id,
        :final name,
        :final size,
        :final mime,
        :final sha256,
        :final chunks,
      ) =>
        {
          't': 'file.offer',
          'id': id,
          'name': name,
          'size': size,
          'mime': mime,
          'sha256': sha256,
          'chunks': chunks,
        },
      FileAcceptFrame(:final id) => {'t': 'file.accept', 'id': id},
      FileDeclineFrame(:final id) => {'t': 'file.decline', 'id': id},
      FileDoneFrame(:final id) => {'t': 'file.done', 'id': id},
      FileAckFrame(:final id) => {'t': 'file.ack', 'id': id},
      FileCancelFrame(:final id, :final reason) => {
        't': 'file.cancel',
        'id': id,
        'reason': ?reason,
      },
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
      case 'file.offer':
        final id = _id(json['id']);
        final rawName = json['name'];
        final size = json['size'];
        final mime = json['mime'];
        final sha = json['sha256'];
        final chunks = json['chunks'];
        if (rawName is! String ||
            size is! int ||
            mime is! String ||
            sha is! String ||
            chunks is! int) {
          throw const ChatFrameException('malformed');
        }
        if (size <= 0 || chunks <= 0 || isBlockedFileType(rawName)) {
          throw const ChatFrameException('malformed');
        }
        final cleanedName = cleanFileName(rawName);
        return FileOfferFrame(
          id: id,
          name: cleanedName,
          size: size,
          mime: cleanText(mime),
          sha256: cleanText(sha),
          chunks: chunks,
        );
      case 'file.accept':
        return FileAcceptFrame(id: _id(json['id']));
      case 'file.decline':
        return FileDeclineFrame(id: _id(json['id']));
      case 'file.done':
        return FileDoneFrame(id: _id(json['id']));
      case 'file.ack':
        return FileAckFrame(id: _id(json['id']));
      case 'file.cancel':
        final reason = json['reason'];
        return FileCancelFrame(
          id: _id(json['id']),
          reason: reason is String ? cleanText(reason) : null,
        );
      case 'bye':
        return const ByeFrame();
      default:
        throw const ChatFrameException('unknown');
    }
  }

  /// Encodes a binary file chunk frame:
  /// 16 bytes file ID (decoded from base64url), 4 bytes chunk index (big-endian), then raw chunk bytes.
  static Uint8List encodeChunk({
    required String fileId,
    required int chunkIndex,
    required List<int> payload,
  }) {
    final idBytes = b64Decode(fileId);
    if (idBytes.length != 16) {
      throw const ChatFrameException('malformed');
    }
    final bytes = Uint8List(20 + payload.length);
    bytes.setRange(0, 16, idBytes);
    final bd = ByteData.sublistView(bytes, 16, 20);
    bd.setUint32(0, chunkIndex, Endian.big);
    bytes.setRange(20, 20 + payload.length, payload);
    return bytes;
  }

  /// Decodes a binary file chunk frame.
  static ({String fileId, int chunkIndex, Uint8List payload}) decodeChunk(
    Uint8List bytes,
  ) {
    if (bytes.length < 20) throw const ChatFrameException('malformed');
    final fileId = b64Encode(bytes.sublist(0, 16));
    final bd = ByteData.sublistView(bytes, 16, 20);
    final chunkIndex = bd.getUint32(0, Endian.big);
    final payload = Uint8List.fromList(bytes.sublist(20));
    return (fileId: fileId, chunkIndex: chunkIndex, payload: payload);
  }

  static final _reservedWindowsNames = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };

  static final _blockedExtensions = {
    '.exe',
    '.msi',
    '.apk',
    '.app',
    '.dmg',
    '.deb',
    '.rpm',
    '.appimage',
    '.bat',
    '.cmd',
    '.ps1',
    '.sh',
    '.vbs',
    '.js',
    '.jar',
    '.scr',
    '.com',
    '.lnk',
  };

  /// Whether a file name has a blocked extension (executables, installers, scripts).
  static bool isBlockedFileType(String filename) {
    final lower = filename.trim().toLowerCase();
    for (final ext in _blockedExtensions) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  /// Cleans a file name per safety specification:
  /// removes path separators, control characters, and leading dots; cuts to 120 chars;
  /// and prefixes reserved Windows names with 'file_'.
  static String cleanFileName(String filename) {
    var name = filename.replaceAll(RegExp(r'\.*[\\/]'), '_');
    name = cleanText(name);
    while (name.startsWith('.')) {
      name = name.substring(1).trim();
    }
    if (name.isEmpty) name = 'file';
    if (name.length > 120) {
      final dot = name.lastIndexOf('.');
      if (dot > 0 && dot > name.length - 20) {
        final ext = name.substring(dot);
        name = '${name.substring(0, 120 - ext.length)}$ext';
      } else {
        name = name.substring(0, 120);
      }
    }
    final baseWithoutExt = name.split('.').first.toUpperCase();
    if (_reservedWindowsNames.contains(baseWithoutExt)) {
      name = 'file_$name';
    }
    return name;
  }

  /// Whether [value] is an id made by [newId]: 16 bytes, unpadded base64url.
  static bool isId(Object? value) =>
      value is String && _idPattern.hasMatch(value);

  static String _id(Object? value) {
    if (!isId(value)) throw const ChatFrameException('malformed');
    return value as String;
  }
}
