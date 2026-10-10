import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:sodium/sodium_sumo.dart';

import '../crypto/encoding.dart';
import '../crypto/passphrase_box.dart';
import '../storage/backup.dart';
import 'chat_store.dart';

/// Why a chat export could not be made or opened.
enum ChatExportProblem {
  /// The passphrase is too short.
  weakPassphrase,

  /// The text is not a Sotto chat export.
  notAnExport,

  /// Made by a newer version of Sotto.
  unsupportedVersion,

  /// Wrong passphrase, or the file was changed or damaged.
  wrongPassphrase,
}

class ChatExportException implements Exception {
  const ChatExportException(this.problem);
  final ChatExportProblem problem;

  @override
  String toString() => 'ChatExportException: ${problem.name}';
}

/// The words of the plain text export. The English defaults serve tests; the
/// export screen passes the words of the person's language.
final class ChatExportLabels {
  const ChatExportLabels({
    this.you = 'You',
    this.exported = 'Exported',
    this.file = 'File',
    this.bytes = 'bytes',
    this.deleted = 'Message deleted',
    this.replyTo = 'Reply to',
    this.reactions = 'Reactions',
    this.edited = 'Edited',
    this.forwarded = 'Forwarded',
    this.delivered = 'Delivered',
    this.read = 'Read',
  });

  final String you;
  final String exported;
  final String file;
  final String bytes;
  final String deleted;
  final String replyTo;
  final String reactions;
  final String edited;
  final String forwarded;
  final String delivered;
  final String read;
}

/// Exports one chat: its messages, as the person reads them.
///
/// This is not a backup. It holds one chat and nothing else: no master secret,
/// keystore or vault value, no identity, no other chat, no pending controls and
/// no chat settings (archived, muted, pinned) and no stars. A file's contents
/// are never included, only its name and size. `docs/PROTOCOL.md`, section 8A,
/// has the format.
///
/// The encrypted file is one line of JSON:
///
/// ```
/// {"sotto":"chat-export","v":1,
///  "kdf":{"alg":"argon2id13","ops":<int>,"mem":<bytes>,"salt":"<16 bytes>"},
///  "nonce":"<24 bytes>","data":["<segment>", …]}
/// ```
///
/// The payload is cut into segments of up to [segmentBytes]. Each segment is
/// sealed under the one key the passphrase derives, with a nonce of its own.
/// So a long chat is written as it is made and never held whole in memory, and
/// the file is still one valid JSON document.
abstract final class ChatExport {
  static const int version = 1;
  static const String _tag = 'chat-export';
  static const String _alg = 'argon2id13';

  /// Labels the additional data, so a segment from another format never opens.
  static const String _label = 'sotto-chat-export-v1';

  /// The passphrase rule, default cost and cost limits of backups.
  static const int minPassphraseLength = Backup.minPassphraseLength;
  static const int defaultOpsLimit = Backup.defaultOpsLimit;
  static const int defaultMemLimit = Backup.defaultMemLimit;
  static const int _maxOpsLimit = 10;
  static const int _minMemLimit = 8 * 1024 * 1024;
  static const int _maxMemLimit = 1024 * 1024 * 1024;

  /// Most payload bytes in one segment. Every segment but the last is exactly
  /// this long.
  static const int segmentBytes = 64 * 1024;

  /// Writes the encrypted export of [messages] to [out], oldest first. The text
  /// goes out as each segment is sealed, so [out] can be a file. [contactName]
  /// is the name the chat shows for the other person.
  static void writeEncrypted(
    StringSink out,
    SodiumSumo sodium, {
    required String passphrase,
    required String contactName,
    required DateTime exportedAt,
    required Iterable<ChatMessage> messages,
    int opsLimit = defaultOpsLimit,
    int memLimit = defaultMemLimit,
    @visibleForTesting Uint8List? fixedSalt,
    @visibleForTesting Uint8List? fixedNonce,
  }) {
    final secret = passphrase.trim();
    if (secret.length < minPassphraseLength) {
      throw const ChatExportException(ChatExportProblem.weakPassphrase);
    }
    // Tests pin the salt and nonce to check the exact bytes. Production passes
    // neither.
    final salt =
        fixedSalt ?? sodium.randombytes.buf(sodium.crypto.pwhash.saltBytes);
    final nonce =
        fixedNonce ??
        sodium.randombytes.buf(
          sodium.crypto.aeadXChaCha20Poly1305IETF.nonceBytes,
        );
    final key = PassphraseBox.derive(
      sodium: sodium,
      passphrase: secret,
      salt: salt,
      opsLimit: opsLimit,
      memLimit: memLimit,
    );
    try {
      final kdf = jsonEncode({
        'alg': _alg,
        'ops': opsLimit,
        'mem': memLimit,
        'salt': b64Encode(salt),
      });
      out.write(
        '{"sotto":"$_tag","v":$version,"kdf":$kdf,'
        '"nonce":"${b64Encode(nonce)}","data":[',
      );
      final header = <Object>[
        version,
        _alg,
        opsLimit,
        memLimit,
        b64Encode(salt),
        b64Encode(nonce),
      ];
      final segments = _Segments(
        key: key,
        out: out,
        header: header,
        fileNonce: nonce,
      );
      _writePayload(
        segments.add,
        contactName: contactName,
        exportedAt: exportedAt,
        messages: messages,
      );
      segments.close();
    } finally {
      key.dispose();
    }
  }

  /// The encrypted export as one string. The same bytes that
  /// [writeEncrypted] writes.
  static String encrypt(
    SodiumSumo sodium, {
    required String passphrase,
    required String contactName,
    required DateTime exportedAt,
    required Iterable<ChatMessage> messages,
    int opsLimit = defaultOpsLimit,
    int memLimit = defaultMemLimit,
    @visibleForTesting Uint8List? fixedSalt,
    @visibleForTesting Uint8List? fixedNonce,
  }) {
    final buffer = StringBuffer();
    writeEncrypted(
      buffer,
      sodium,
      passphrase: passphrase,
      contactName: contactName,
      exportedAt: exportedAt,
      messages: messages,
      opsLimit: opsLimit,
      memLimit: memLimit,
      fixedSalt: fixedSalt,
      fixedNonce: fixedNonce,
    );
    return buffer.toString();
  }

  /// Opens an encrypted export and returns its payload, as decoded JSON.
  /// Throws [ChatExportException].
  static Map<String, Object?> open(
    SodiumSumo sodium,
    String text,
    String passphrase,
  ) {
    final int ops, mem;
    final Uint8List salt, nonce;
    final List<Uint8List> segments;
    try {
      final json = jsonDecode(text.trim()) as Map<String, dynamic>;
      if (json['sotto'] != _tag) {
        throw const ChatExportException(ChatExportProblem.notAnExport);
      }
      if (json['v'] != version) {
        throw const ChatExportException(ChatExportProblem.unsupportedVersion);
      }
      final kdf = json['kdf'] as Map<String, dynamic>;
      if (kdf['alg'] != _alg) {
        throw const ChatExportException(ChatExportProblem.unsupportedVersion);
      }
      ops = kdf['ops'] as int;
      mem = kdf['mem'] as int;
      salt = b64Decode(kdf['salt'] as String);
      nonce = b64Decode(json['nonce'] as String);
      segments = [
        for (final data in json['data'] as List<dynamic>)
          b64Decode(data as String),
      ];
    } on ChatExportException {
      rethrow;
    } catch (_) {
      throw const ChatExportException(ChatExportProblem.notAnExport);
    }
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    if (ops < 1 ||
        ops > _maxOpsLimit ||
        mem < _minMemLimit ||
        mem > _maxMemLimit ||
        salt.length != sodium.crypto.pwhash.saltBytes ||
        nonce.length != aead.nonceBytes ||
        segments.isEmpty) {
      throw const ChatExportException(ChatExportProblem.notAnExport);
    }

    final header = <Object>[
      version,
      _alg,
      ops,
      mem,
      b64Encode(salt),
      b64Encode(nonce),
    ];
    final key = PassphraseBox.derive(
      sodium: sodium,
      passphrase: passphrase.trim(),
      salt: salt,
      opsLimit: ops,
      memLimit: mem,
    );
    try {
      final payload = BytesBuilder(copy: false);
      for (var i = 0; i < segments.length; i++) {
        final opened = key.open(
          nonce: _segmentNonce(nonce, i),
          additionalData: _segmentAd(header, i, last: i == segments.length - 1),
          cipher: segments[i],
        );
        if (opened == null) {
          throw const ChatExportException(ChatExportProblem.wrongPassphrase);
        }
        payload.add(opened);
      }
      final json = jsonDecode(utf8.decode(payload.takeBytes()));
      if (json is! Map<String, dynamic>) {
        throw const ChatExportException(ChatExportProblem.notAnExport);
      }
      return json;
    } on FormatException {
      throw const ChatExportException(ChatExportProblem.notAnExport);
    } finally {
      key.dispose();
    }
  }

  /// The nonce of segment [index]: the first 16 bytes of the file's nonce, then
  /// the index as 8 big-endian bytes. The index is also in the additional data.
  static Uint8List _segmentNonce(Uint8List fileNonce, int index) {
    final counter = ByteData(8)..setUint64(0, index);
    return concatBytes([
      fileNonce.sublist(0, 16),
      counter.buffer.asUint8List(),
    ]);
  }

  /// The additional data of a segment: the format label, the header fields,
  /// the segment's index, and whether it is the last. Changing any of them, or
  /// dropping or reordering segments, fails to open.
  static Uint8List _segmentAd(
    List<Object> header,
    int index, {
    required bool last,
  }) => concatBytes([
    domainLabel(_label),
    utf8.encode(jsonEncode([...header, index, last])),
  ]);

  /// Writes [messages] as plain text, oldest first, one message at a time.
  /// Nothing is encrypted: whoever has the file can read the chat. The export
  /// screen warns before it is written.
  static void writePlain(
    StringSink out, {
    required String contactName,
    required DateTime exportedAt,
    required Iterable<ChatMessage> messages,
    ChatExportLabels labels = const ChatExportLabels(),
  }) {
    out.write(
      '$contactName\n${labels.exported} ${_time(exportedAt.millisecondsSinceEpoch)}\n',
    );
    for (final message in messages) {
      final lines = _plainLines(
        message,
        contactName: contactName,
        labels: labels,
      );
      out.write('\n${lines.join('\n')}\n');
    }
  }

  /// The lines of one message: its time, sender and text, then an indented
  /// line for each mark or detail it has.
  static List<String> _plainLines(
    ChatMessage message, {
    required String contactName,
    required ChatExportLabels labels,
  }) {
    final sender = message.outgoing ? labels.you : contactName;
    return [
      '[${_time(message.ts)}] $sender: ${_plainBody(message, labels)}',
      if (message.replyTo case final quote?)
        '    ${labels.replyTo}: "${quote.text}"',
      if (message.reactions.isNotEmpty)
        '    ${labels.reactions}: '
            '${_plainReactions(message, contactName, labels)}',
      if (message.editedAt case final at?) '    ${labels.edited} ${_time(at)}',
      if (message.forwarded) '    ${labels.forwarded}',
      if (message.deliveredAt case final at?)
        '    ${labels.delivered} ${_time(at)}',
      if (message.readAt case final at?) '    ${labels.read} ${_time(at)}',
    ];
  }

  static String _plainBody(ChatMessage message, ChatExportLabels labels) {
    if (message.deletedForAll) return labels.deleted;
    if (!message.isAttachment) return message.text;
    final size = message.fileSize;
    final detail = size == null ? '' : ' ($size ${labels.bytes})';
    return '${labels.file}: ${message.fileName}$detail';
  }

  static String _plainReactions(
    ChatMessage message,
    String contactName,
    ChatExportLabels labels,
  ) => [
    for (final who in const ['me', 'peer'])
      if (message.reactions[who] case final emoji?)
        '$emoji (${who == 'me' ? labels.you : contactName})',
  ].join(', ');

  /// A time in milliseconds since the epoch, as UTC to the second, such as
  /// 2026-10-10T12:00:00Z.
  static String _time(int ms) {
    final utc = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    return '${utc.toIso8601String().split('.').first}Z';
  }

  /// Writes the payload, one message at a time, through [write].
  static void _writePayload(
    void Function(String text) write, {
    required String contactName,
    required DateTime exportedAt,
    required Iterable<ChatMessage> messages,
  }) {
    write(
      '{"with":${jsonEncode(contactName)},'
      '"exported":${jsonEncode(exportedAt.toUtc().toIso8601String())},'
      '"messages":[',
    );
    var first = true;
    for (final message in messages) {
      if (!first) write(',');
      first = false;
      write(jsonEncode(_record(message)));
    }
    write(']}');
  }

  /// One message in the payload. `out` is true for the owner's own messages;
  /// for the others the sender is the contact named in `with`. A deleted
  /// message keeps only its times and its mark: its text, file and reactions
  /// are gone from the chat, so they stay out of the export.
  static Map<String, Object?> _record(ChatMessage message) => {
    'out': message.outgoing,
    'sent': message.ts,
    'delivered': ?message.deliveredAt,
    'read': ?message.readAt,
    'edited': ?message.editedAt,
    if (message.forwarded) 'forwarded': true,
    ..._content(message),
  };

  static Map<String, Object?> _content(ChatMessage message) {
    if (message.deletedForAll) return {'deleted': true};
    return {
      if (message.isAttachment)
        'file': {'name': message.fileName, 'size': ?message.fileSize}
      else
        'text': message.text,
      if (message.replyTo case final quote?) 'quote': quote.text,
      if (message.reactions.isNotEmpty)
        'reactions': [
          for (final who in const ['me', 'peer'])
            if (message.reactions[who] case final emoji?)
              {'out': who == 'me', 'emoji': emoji},
        ],
    };
  }
}

/// Seals the payload in segments as it is written. A segment is sealed only
/// once more text has come after it, so the last one, and only the last, is
/// marked final in its additional data.
final class _Segments {
  _Segments({
    required this.key,
    required this.out,
    required this.header,
    required this.fileNonce,
  });

  final PassphraseKey key;
  final StringSink out;
  final List<Object> header;
  final Uint8List fileNonce;
  final _pending = BytesBuilder();
  var _count = 0;

  void add(String text) {
    _pending.add(utf8.encode(text));
    while (_pending.length > ChatExport.segmentBytes) {
      final bytes = _pending.takeBytes();
      _seal(
        Uint8List.sublistView(bytes, 0, ChatExport.segmentBytes),
        last: false,
      );
      _pending.add(Uint8List.sublistView(bytes, ChatExport.segmentBytes));
    }
  }

  void close() {
    _seal(_pending.takeBytes(), last: true);
    out.write(']}');
  }

  void _seal(Uint8List plain, {required bool last}) {
    final index = _count++;
    final cipher = key.seal(
      nonce: ChatExport._segmentNonce(fileNonce, index),
      additionalData: ChatExport._segmentAd(header, index, last: last),
      plain: plain,
    );
    if (index > 0) out.write(',');
    out.write('"${b64Encode(cipher)}"');
  }
}
