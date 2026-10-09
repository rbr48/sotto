import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/encoding.dart';
import 'voice/voice_format.dart';

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

/// The longest file name a file offer may carry, before cleaning (characters).
const int maxFileNameChars = 512;

/// The longest file name kept, in UTF-8 bytes, extension included.
const int maxFileNameBytes = 120;

/// The longest extension kept whole. A longer one is cut to this many bytes.
const int maxExtensionBytes = 40;

/// The longest MIME type a file offer may carry (characters).
const int maxMimeChars = 128;

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
    this.blocked = false,
    this.voice = false,
  });

  /// 16 random bytes, unpadded base64url.
  final String id;

  /// The name after cleaning.
  final String name;
  final int size;
  final String mime;
  final String sha256;
  final int chunks;

  /// Whether the name as sent, or the name after cleaning, has a blocked type.
  /// Set when the frame is decoded; a frame that is not decoded is not blocked
  /// unless it says so.
  final bool blocked;

  /// Whether the offer is a voice note (`kind` is `voice` on the wire). An
  /// offer without a kind is a plain file, whatever its MIME type.
  final bool voice;
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
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

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
        :final voice,
      ) =>
        {
          't': 'file.offer',
          'id': id,
          'name': name,
          'size': size,
          'mime': mime,
          'sha256': sha256,
          'chunks': chunks,
          // Only a voice note carries a kind. Older clients ignore it.
          if (voice) 'kind': voiceOfferKind,
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
        // A blocked type is not refused here. The session declines it, as it
        // declines a file that is too large.
        if (rawName.isEmpty || rawName.runes.length > maxFileNameChars) {
          throw const ChatFrameException('malformed');
        }
        if (size < 1 || size > maxFileSizeNative) {
          throw const ChatFrameException('malformed');
        }
        if (chunks != (size + fileChunkSize - 1) ~/ fileChunkSize) {
          throw const ChatFrameException('malformed');
        }
        if (mime.runes.length > maxMimeChars || !_sha256Pattern.hasMatch(sha)) {
          throw const ChatFrameException('malformed');
        }
        // A kind is optional. Absent, or 'file', is a plain file. Anything
        // else is not a kind this app knows, so the frame is refused.
        final rawKind = json['kind'];
        if (rawKind != null && rawKind != 'file' && rawKind != voiceOfferKind) {
          throw const ChatFrameException('malformed');
        }
        final name = cleanFileName(rawName);
        return FileOfferFrame(
          id: id,
          name: name,
          size: size,
          mime: cleanText(mime),
          sha256: sha,
          chunks: chunks,
          // Judged on the name as sent too: cleaning can hide a blocked type
          // from the cleaned name, and the sender refuses such a name.
          blocked: isBlockedFileType(rawName) || isBlockedFileType(name),
          voice: rawKind == voiceOfferKind,
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

  /// The device names Windows reserves, in upper case. The superscript digits
  /// are the ones Windows also treats as COM and LPT ports.
  static final _reservedWindowsNames = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'CONIN\$',
    'CONOUT\$',
    'COM0',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'COM¹',
    'COM²',
    'COM³',
    'LPT0',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
    'LPT¹',
    'LPT²',
    'LPT³',
  };

  /// File types that are never shared: executables, installers, scripts and
  /// shortcuts; pages that a browser runs; macro-enabled Office files; and disk
  /// images, which can hold any of these.
  static final _blockedExtensions = {
    '.exe',
    '.msi',
    '.apk',
    '.app',
    '.dmg',
    '.deb',
    '.rpm',
    '.appimage',
    '.pkg',
    '.command',
    '.ipa',
    '.xap',
    '.crx',
    '.msp',
    '.mst',
    '.msc',
    '.cpl',
    '.hta',
    '.pif',
    '.gadget',
    '.com',
    '.scr',
    '.bat',
    '.cmd',
    '.ps1',
    '.sh',
    '.vbs',
    '.vb',
    '.vbe',
    '.js',
    '.jse',
    '.wsf',
    '.wsh',
    '.reg',
    '.inf',
    '.url',
    '.scf',
    '.lnk',
    '.html',
    '.htm',
    '.xhtml',
    '.shtml',
    '.mht',
    '.mhtml',
    '.svg',
    '.svgz',
    '.chm',
    '.jar',
    '.docm',
    '.dotm',
    '.xlsm',
    '.xlsb',
    '.pptm',
    '.iso',
    '.img',
    '.vhd',
    '.vhdx',
    // Windows app packages (installers), update packages and script components.
    '.msix',
    '.msixbundle',
    '.appx',
    '.appxbundle',
    '.msu',
    '.sct',
    '.wsc',
    '.ws',
    '.jnlp',
    '.application',
    '.appref-ms',
    '.library-ms',
    // Office add-ins and macro-enabled templates and slide shows.
    '.xlam',
    '.xla',
    '.ppam',
    '.ppsm',
    '.potm',
    '.xltm',
  };

  /// Whether [rune] is a control or an invisible format character: U+0000 to
  /// U+001F, U+007F to U+009F, U+200B to U+200F, U+202A to U+202E, U+2066 to
  /// U+2069, or U+FEFF. These are removed before a name is checked.
  static bool _isInvisible(int rune) =>
      rune < 0x20 ||
      (rune >= 0x7F && rune <= 0x9F) ||
      (rune >= 0x200B && rune <= 0x200F) ||
      (rune >= 0x202A && rune <= 0x202E) ||
      (rune >= 0x2066 && rune <= 0x2069) ||
      rune == 0xFEFF;

  /// Whether a file name has a blocked type.
  ///
  /// The check is on the final extension (the text after the last dot) of the
  /// last path segment, once the name is normalised: control and invisible
  /// characters are removed, trailing dots and spaces are stripped, and the
  /// case is folded. So a path, a trailing dot or space, a control character
  /// or a direction override cannot hide the type. A name with no dot is not
  /// blocked.
  ///
  /// A colon is not special here. [cleanFileName] turns it into an underscore,
  /// so "setup.exe::$DATA" is stored as the plain name "setup.exe__$DATA".
  static bool isBlockedFileType(String filename) {
    final name = _normalisedName(filename);
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _blockedExtensions.contains(name.substring(dot));
  }

  /// The last path segment of [filename], without invisible characters, with
  /// trailing spaces and dots stripped, in lower case.
  static String _normalisedName(String filename) {
    final segment = filename.split(RegExp(r'[\\/]')).last;
    final visible = StringBuffer();
    for (final rune in segment.runes) {
      if (!_isInvisible(rune)) visible.writeCharCode(rune);
    }
    var name = visible.toString().trimRight();
    while (name.endsWith('.')) {
      name = name.substring(0, name.length - 1).trimRight();
    }
    return name.toLowerCase();
  }

  /// Cleans a file name for storing and showing.
  ///
  /// Path separators become `_`, and so do colons, which Windows reads as the
  /// start of a stream name. Control, invisible and direction-changing
  /// characters, and lone surrogates, are removed. Leading dots are dropped,
  /// and a name with nothing left becomes `file`. A base name that is a
  /// reserved Windows device name gets `file_` in front.
  ///
  /// The result is at most [maxFileNameBytes] UTF-8 bytes. The stem is cut at a
  /// character boundary, and the extension (from the last dot) is kept whole,
  /// unless it is longer than [maxExtensionBytes], when it is cut to that
  /// length. The reserved-name check comes after the cut, which can leave a
  /// bare reserved name. The result never contains a slash, a backslash, a
  /// colon, an invisible character or a control character, and cleaning it
  /// again changes nothing.
  static String cleanFileName(String filename) {
    var name = filename.replaceAll(RegExp(r'\.*[\\/]'), '_');
    name = _withoutInvisible(name).replaceAll(':', '_').trim();
    while (name.startsWith('.')) {
      name = name.substring(1).trim();
    }
    if (name.isEmpty) name = 'file';
    name = _capBytes(name, maxFileNameBytes);
    if (_isReservedName(name)) {
      name = _capBytes('file_$name', maxFileNameBytes);
    }
    return name;
  }

  /// Whether the base of [name] (the text before the first dot) is a reserved
  /// Windows device name.
  static bool _isReservedName(String name) {
    final base = name.split('.').first.trimRight().toUpperCase();
    return _reservedWindowsNames.contains(base);
  }

  /// [input] without the characters [_isInvisible] names (control characters
  /// included, line breaks and tabs too) and without lone surrogates.
  static String _withoutInvisible(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      final dropped = _isInvisible(rune) || (rune >= 0xD800 && rune <= 0xDFFF);
      if (!dropped) buffer.writeCharCode(rune);
    }
    return buffer.toString();
  }

  /// [name] cut to at most [maxBytes] UTF-8 bytes, keeping the extension.
  static String _capBytes(String name, int maxBytes) {
    if (_byteLength(name) <= maxBytes) return name;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    var ext = dot > 0 ? name.substring(dot) : '';
    if (_byteLength(ext) > maxExtensionBytes) {
      // A cut that ends in spaces loses them, so a second clean changes
      // nothing. A lone dot left by the cut is dropped as well.
      ext = _cutBytes(ext, maxExtensionBytes).trimRight();
      if (ext == '.') ext = '';
    }
    final room = maxBytes - _byteLength(ext);
    return '${_cutBytes(stem, room).trimRight()}$ext';
  }

  static int _byteLength(String text) => utf8.encode(text).length;

  /// The longest prefix of [text] that is at most [maxBytes] UTF-8 bytes. It
  /// never splits a character.
  static String _cutBytes(String text, int maxBytes) {
    final buffer = StringBuffer();
    var used = 0;
    for (final rune in text.runes) {
      final size = _runeBytes(rune);
      if (used + size > maxBytes) break;
      used += size;
      buffer.writeCharCode(rune);
    }
    return buffer.toString();
  }

  /// The number of UTF-8 bytes that [rune] takes.
  static int _runeBytes(int rune) {
    if (rune < 0x80) return 1;
    if (rune < 0x800) return 2;
    if (rune < 0x10000) return 3;
    return 4;
  }

  /// Whether [value] is an id made by [newId]: 16 bytes, unpadded base64url.
  static bool isId(Object? value) =>
      value is String && _idPattern.hasMatch(value);

  static String _id(Object? value) {
    if (!isId(value)) throw const ChatFrameException('malformed');
    return value as String;
  }

  /// Detects MIME type from filename extension and/or file magic bytes.
  static String detectMimeType(String name, [Uint8List? bytes]) {
    if (bytes != null && bytes.length >= 4) {
      if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
        return 'image/jpeg';
      }
      if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
        return 'image/png';
      }
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
        return 'image/gif';
      }
      if (bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46) {
        return 'application/pdf';
      }
      if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) {
        if (bytes.length >= 12) {
          final form = String.fromCharCodes(bytes.sublist(8, 12));
          if (form == 'WEBP') return 'image/webp';
          if (form == 'WAVE') return 'audio/wav';
        }
      }
    }
    final dot = name.lastIndexOf('.');
    if (dot >= 0) {
      final ext = name.substring(dot + 1).toLowerCase();
      switch (ext) {
        case 'jpg':
        case 'jpeg':
          return 'image/jpeg';
        case 'png':
          return 'image/png';
        case 'webp':
          return 'image/webp';
        case 'gif':
          return 'image/gif';
        case 'svg':
          return 'image/svg+xml';
        case 'pdf':
          return 'application/pdf';
        case 'mp4':
          return 'video/mp4';
        case 'm4v':
        case 'mov':
          return 'video/quicktime';
        case 'mkv':
          return 'video/x-matroska';
        case 'webm':
          return 'video/webm';
        case 'mp3':
          return 'audio/mpeg';
        case 'm4a':
        case 'aac':
          return 'audio/mp4';
        case 'wav':
          return 'audio/wav';
        case 'ogg':
        case 'oga':
          return 'audio/ogg';
        case 'opus':
          return 'audio/opus';
        case 'txt':
          return 'text/plain';
        case 'csv':
          return 'text/csv';
        case 'html':
        case 'htm':
          return 'text/html';
        case 'json':
          return 'application/json';
        case 'zip':
          return 'application/zip';
        case 'tar':
        case 'gz':
          return 'application/gzip';
        case 'doc':
          return 'application/msword';
        case 'docx':
          return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
        case 'xls':
          return 'application/vnd.ms-excel';
        case 'xlsx':
          return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
        case 'ppt':
          return 'application/vnd.ms-powerpoint';
        case 'pptx':
          return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      }
    }
    return 'application/octet-stream';
  }
}
