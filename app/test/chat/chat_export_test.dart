import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sotto/chat/chat_export.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

// Cheap cost keeps these tests fast; the backup tests cover the defaults.
const _passphrase = 'a long passphrase';
const _ops = 1;
const _mem = 8 << 20;
final _exportedAt = DateTime.utc(2026, 10, 10, 12);
final _fixedSalt = Uint8List.fromList(List.generate(16, (i) => i + 1));
final _fixedNonce = Uint8List.fromList(List.generate(24, (i) => i + 101));

const _bobId = 'bob-sotto-id-0000000001';
const _carolId = 'carol-sotto-id-000000002';

String _msgId(int n) {
  final bytes = Uint8List(16);
  ByteData.sublistView(bytes).setUint32(12, n);
  return b64Encode(bytes);
}

ChatMessage _message(
  int n, {
  String contact = _bobId,
  bool outgoing = true,
  String text = 'hi',
  int? deliveredAt,
  int? readAt,
  int? editedAt,
  bool forwarded = false,
  bool starred = false,
  bool deletedForAll = false,
  ChatReply? replyTo,
  Map<String, String> reactions = const {},
}) => ChatMessage(
  id: _msgId(n),
  contactId: contact,
  outgoing: outgoing,
  ts: 1700000000000 + n,
  text: text,
  state: ChatState.delivered,
  deliveredAt: deliveredAt,
  readAt: readAt,
  editedAt: editedAt,
  forwarded: forwarded,
  starred: starred,
  deletedForAll: deletedForAll,
  replyTo: replyTo,
  reactions: reactions,
);

ChatMessage _file(int n) => ChatMessage(
  id: _msgId(n),
  contactId: _bobId,
  outgoing: true,
  ts: 1700000000000 + n,
  text: 'report.pdf',
  state: ChatState.delivered,
  fileId: 'FILE-ID-XYZ',
  fileName: 'report.pdf',
  fileSize: 5120,
  fileMime: 'application/x-mime-XYZ',
  fileSha256: 'SHA256-VALUE-XYZ',
  fileStatus: 'accepted-XYZ',
  filePath: '/private/PATH-VALUE-XYZ',
  fileKey: 'KEY-VALUE-XYZ',
);

/// Bob's chat, as the store holds it: every field the export reads.
List<ChatMessage> _bobChat() => [
  _message(1, outgoing: false, text: 'Hello from Bob'),
  _message(
    2,
    text: 'Hi Bob',
    deliveredAt: 1700000000502,
    readAt: 1700000001003,
    reactions: const {'peer': '👍'},
  ),
  _message(
    3,
    text: 'Replying',
    replyTo: (id: _msgId(1), text: 'Hello from Bob'),
  ),
  _message(4, text: 'Edited text', editedAt: 1700000000777),
  _message(
    5,
    outgoing: false,
    text: 'Forwarded text',
    forwarded: true,
    starred: true,
    reactions: const {'me': '❤️', 'peer': '😂'},
  ),
  _file(6),
  _message(7, deletedForAll: true, text: ''),
];

/// The payload [_bobChat] must decode to, written out by hand.
final _bobPayload = {
  'with': 'Bob',
  'exported': '2026-10-10T12:00:00.000Z',
  'messages': [
    {'out': false, 'sent': 1700000000001, 'text': 'Hello from Bob'},
    {
      'out': true,
      'sent': 1700000000002,
      'delivered': 1700000000502,
      'read': 1700000001003,
      'text': 'Hi Bob',
      'reactions': [
        {'out': false, 'emoji': '👍'},
      ],
    },
    {
      'out': true,
      'sent': 1700000000003,
      'text': 'Replying',
      'quote': 'Hello from Bob',
    },
    {
      'out': true,
      'sent': 1700000000004,
      'text': 'Edited text',
      'edited': 1700000000777,
    },
    {
      'out': false,
      'sent': 1700000000005,
      'text': 'Forwarded text',
      'forwarded': true,
      'reactions': [
        {'out': true, 'emoji': '❤️'},
        {'out': false, 'emoji': '😂'},
      ],
    },
    {
      'out': true,
      'sent': 1700000000006,
      'file': {'name': 'report.pdf', 'size': 5120},
    },
    {'out': true, 'sent': 1700000000007, 'deleted': true},
  ],
};

/// The keys PROTOCOL.md section 8A documents for a payload. Any other key in an
/// export is a leak until the spec says otherwise.
const _documentedKeys = {
  'with',
  'exported',
  'messages',
  'out',
  'sent',
  'delivered',
  'read',
  'edited',
  'forwarded',
  'text',
  'file',
  'name',
  'size',
  'quote',
  'reactions',
  'emoji',
  'deleted',
};

Matcher _problem(ChatExportProblem problem) =>
    isA<ChatExportException>().having((e) => e.problem, 'problem', problem);

/// Records each write, so a test can see that the export came in pieces.
class _PieceSink implements StringSink {
  final pieces = <String>[];

  @override
  void write(Object? object) => pieces.add('$object');

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      pieces.add(objects.join(separator));

  @override
  void writeCharCode(int charCode) => pieces.add(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => pieces.add('$object\n');
}

void main() {
  late SodiumSumo sodium;
  setUpAll(
    () async => sodium = SottoCrypto.passwordHashing(await SottoCrypto.init())!,
  );

  String encrypt(
    List<ChatMessage> messages, {
    String passphrase = _passphrase,
    String contactName = 'Bob',
  }) => ChatExport.encrypt(
    sodium,
    passphrase: passphrase,
    contactName: contactName,
    exportedAt: _exportedAt,
    messages: messages,
    opsLimit: _ops,
    memLimit: _mem,
    fixedSalt: _fixedSalt,
    fixedNonce: _fixedNonce,
  );

  Map<String, Object?> open(String text, {String passphrase = _passphrase}) =>
      ChatExport.open(sodium, text, passphrase);

  test('the encrypted file has the header, and the payload is the chat', () {
    final text = encrypt(_bobChat());
    final json = jsonDecode(text) as Map<String, dynamic>;
    expect(json.keys.toList(), ['sotto', 'v', 'kdf', 'nonce', 'data']);
    expect(json['sotto'], 'chat-export');
    expect(json['v'], 1);
    expect(json['kdf'], {
      'alg': 'argon2id13',
      'ops': _ops,
      'mem': _mem,
      'salt': b64Encode(_fixedSalt),
    });
    expect(json['nonce'], b64Encode(_fixedNonce));
    expect(json['data'], hasLength(1), reason: 'a short chat is one segment');

    expect(open(text), _bobPayload);
  });

  test('a wrong passphrase fails; spaces around it do not matter', () {
    final text = encrypt(_bobChat());
    expect(
      () => open(text, passphrase: 'a long passphrasE'),
      throwsA(_problem(ChatExportProblem.wrongPassphrase)),
    );
    expect(
      () => open(text, passphrase: 'a long passphrase '),
      returnsNormally,
      reason: 'surrounding spaces are trimmed, as in backups',
    );
  });

  test(
    'the payload has no master secret, keystore value, identity or other chat',
    () async {
      final master = Uint8List.fromList(
        List.generate(32, (i) => (i * 37 + 11) & 0xff),
      );
      final vaultKey = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final secrets = MemorySecretStore();
      await secrets.write('sotto.identity.master.v1', b64Encode(master));
      await secrets.write('sotto.vault.key.v1', b64Encode(vaultKey));
      final store = ChatStore(secrets);
      for (final message in _bobChat()) {
        await store.add(message);
      }
      await store.add(
        _message(
          9,
          contact: _carolId,
          outgoing: false,
          text: 'A message from Carol',
        ),
      );

      final text = ChatExport.encrypt(
        sodium,
        passphrase: _passphrase,
        contactName: 'Bob',
        exportedAt: _exportedAt,
        messages: await store.messages(_bobId),
        opsLimit: _ops,
        memLimit: _mem,
      );
      final dump = jsonEncode(open(text));
      final needles = [
        b64Encode(master),
        base64.encode(master),
        b64Encode(vaultKey),
        base64.encode(vaultKey),
        _carolId,
        _bobId,
        'A message from Carol',
      ];
      for (final needle in needles) {
        expect(dump, isNot(contains(needle)), reason: needle);
      }
      expect(dump, contains('Hello from Bob'), reason: 'the chat is there');
    },
  );

  test('pending controls and chat settings stay out of the export', () async {
    final store = ChatStore(MemorySecretStore());
    for (final message in _bobChat()) {
      await store.add(message);
    }
    await store.queueControl(
      _bobId,
      ReactFrame(id: _msgId(1), emoji: '🙈', ts: 1700000000900),
    );
    await store.setArchived(_bobId, true);
    await store.setMuted(_bobId, true);
    await store.setPinned(_bobId, true, at: 1700000000950);

    final dump = jsonEncode(open(encrypt(await store.messages(_bobId))));
    expect(dump, isNot(contains('🙈')), reason: 'a pending reaction');
    for (final key in [
      'archived',
      'muted',
      'pinned',
      'starred',
      'pendingControls',
    ]) {
      expect(dump, isNot(contains(key)), reason: key);
    }
    expect(dump, contains('Hi Bob'));
  });

  test('the payload has only the documented keys, and no message id', () {
    final payload = open(encrypt(_bobChat()));
    final keys = <String>{};
    void collect(Object? node) {
      if (node is Map) {
        for (final entry in node.entries) {
          keys.add(entry.key as String);
          collect(entry.value);
        }
      } else if (node is List) {
        node.forEach(collect);
      }
    }

    collect(payload);
    expect(
      keys.difference(_documentedKeys),
      isEmpty,
      reason: 'keys that section 8A does not document',
    );

    final plain = StringBuffer();
    ChatExport.writePlain(
      plain,
      contactName: 'Bob',
      exportedAt: _exportedAt,
      messages: _bobChat(),
    );
    final dump = jsonEncode(payload);
    for (var n = 1; n <= 7; n++) {
      expect(dump, isNot(contains(_msgId(n))), reason: 'message $n in JSON');
      expect(
        plain.toString(),
        isNot(contains(_msgId(n))),
        reason: 'message $n',
      );
    }
  });

  test('a file exports its name and size, never its bytes or its keys', () {
    final payload = open(encrypt([_file(6)]));
    expect(payload['messages'], [
      {
        'out': true,
        'sent': 1700000000006,
        'file': {'name': 'report.pdf', 'size': 5120},
      },
    ]);
    final dump = jsonEncode(payload);
    for (final value in [
      'FILE-ID-XYZ',
      'SHA256-VALUE-XYZ',
      'PATH-VALUE-XYZ',
      'KEY-VALUE-XYZ',
      'accepted-XYZ',
      'application/x-mime-XYZ',
    ]) {
      expect(dump, isNot(contains(value)), reason: value);
    }
  });

  test('a long chat is sealed in several segments and opens whole', () {
    final messages = [
      for (var i = 0; i < 1200; i++)
        _message(i + 1, text: 'message $i ${'x' * 150}'),
    ];
    final text = encrypt(messages);
    final json = jsonDecode(text) as Map<String, dynamic>;
    expect(json['data'], hasLength(greaterThan(3)));
    final list = open(text)['messages'] as List<dynamic>;
    expect(list, hasLength(1200));
    expect(list.last, containsPair('text', 'message 1199 ${'x' * 150}'));
  });

  test('writing in pieces gives the same bytes as one shot', () async {
    final messages = [
      for (var i = 0; i < 1200; i++)
        _message(i + 1, text: 'message $i ${'x' * 150}'),
    ];
    final oneShot = encrypt(messages);

    final pieces = _PieceSink();
    ChatExport.writeEncrypted(
      pieces,
      sodium,
      passphrase: _passphrase,
      contactName: 'Bob',
      exportedAt: _exportedAt,
      messages: messages,
      opsLimit: _ops,
      memLimit: _mem,
      fixedSalt: _fixedSalt,
      fixedNonce: _fixedNonce,
    );
    expect(pieces.pieces.join(), oneShot);
    expect(
      pieces.pieces.length,
      greaterThan(3),
      reason: 'the header, each segment, and the end, not one string',
    );

    final dir = await Directory.systemTemp.createTemp('sotto-chat-export');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.export');
    final sink = file.openWrite();
    ChatExport.writeEncrypted(
      sink,
      sodium,
      passphrase: _passphrase,
      contactName: 'Bob',
      exportedAt: _exportedAt,
      messages: messages,
      opsLimit: _ops,
      memLimit: _mem,
      fixedSalt: _fixedSalt,
      fixedNonce: _fixedNonce,
    );
    await sink.close();
    expect(await file.readAsString(), oneShot);
  });

  test('a changed, dropped or reordered segment does not open', () {
    final messages = [
      for (var i = 0; i < 1200; i++)
        _message(i + 1, text: 'message $i ${'x' * 150}'),
    ];
    final json = jsonDecode(encrypt(messages)) as Map<String, dynamic>;
    final data = (json['data'] as List<dynamic>).cast<String>();
    String withData(List<String> segments) =>
        jsonEncode({...json, 'data': segments});

    final flipped = b64Decode(data[0])..[7] ^= 1;
    expect(
      () => open(withData([b64Encode(flipped), ...data.skip(1)])),
      throwsA(_problem(ChatExportProblem.wrongPassphrase)),
      reason: 'changed bytes',
    );
    expect(
      () => open(withData(data.sublist(0, data.length - 1))),
      throwsA(_problem(ChatExportProblem.wrongPassphrase)),
      reason: 'a dropped last segment',
    );
    expect(
      () => open(withData([data[1], data[0], ...data.skip(2)])),
      throwsA(_problem(ChatExportProblem.wrongPassphrase)),
      reason: 'reordered segments',
    );
  });

  test('a file of another kind, or of a newer version, is refused', () {
    final text = encrypt(_bobChat());
    final json = jsonDecode(text) as Map<String, dynamic>;
    expect(
      () => open(jsonEncode({...json, 'sotto': 'backup'})),
      throwsA(_problem(ChatExportProblem.notAnExport)),
      reason: 'a backup is not a chat export',
    );
    expect(
      () => open(jsonEncode({...json, 'v': 2})),
      throwsA(_problem(ChatExportProblem.unsupportedVersion)),
    );
    expect(
      () => open('not json'),
      throwsA(_problem(ChatExportProblem.notAnExport)),
    );
    expect(
      () => open(jsonEncode({...json, 'data': <String>[]})),
      throwsA(_problem(ChatExportProblem.notAnExport)),
    );
  });

  test('a star stays out of both formats', () {
    final starred = _message(
      1,
      outgoing: false,
      text: 'Keep this',
      starred: true,
    );
    expect(open(encrypt([starred]))['messages'], [
      {'out': false, 'sent': 1700000000001, 'text': 'Keep this'},
    ]);

    final buffer = StringBuffer();
    ChatExport.writePlain(
      buffer,
      contactName: 'Bob',
      exportedAt: _exportedAt,
      messages: [starred],
    );
    expect(buffer.toString().toLowerCase(), isNot(contains('starred')));
  });

  test('a short passphrase is refused before anything is written', () {
    expect(
      () => encrypt(_bobChat(), passphrase: 'too short'),
      throwsA(_problem(ChatExportProblem.weakPassphrase)),
    );
  });

  group('plain text', () {
    String plain(
      List<ChatMessage> messages, {
      ChatExportLabels labels = const ChatExportLabels(),
    }) {
      final buffer = StringBuffer();
      ChatExport.writePlain(
        buffer,
        contactName: 'Bob',
        exportedAt: _exportedAt,
        messages: messages,
        labels: labels,
      );
      return buffer.toString();
    }

    test('reads as the chat does, with each mark on its own line', () {
      expect(plain(_bobChat()), _bobPlainText);
    });

    test('has no keys, pending controls, settings or other chats', () async {
      final master = Uint8List.fromList(
        List.generate(32, (i) => (i * 37 + 11) & 0xff),
      );
      final vaultKey = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final secrets = MemorySecretStore();
      await secrets.write('sotto.identity.master.v1', b64Encode(master));
      await secrets.write('sotto.vault.key.v1', b64Encode(vaultKey));
      final store = ChatStore(secrets);
      for (final message in _bobChat()) {
        await store.add(message);
      }
      await store.add(
        _message(
          9,
          contact: _carolId,
          outgoing: false,
          text: 'A message from Carol',
        ),
      );
      await store.queueControl(
        _bobId,
        ReactFrame(id: _msgId(1), emoji: '🙈', ts: 1700000000900),
      );
      await store.setArchived(_bobId, true);
      await store.setMuted(_bobId, true);
      await store.setPinned(_bobId, true, at: 1700000000950);

      final text = plain(await store.messages(_bobId));
      expect(text, contains('Hello from Bob'));
      final needles = [
        b64Encode(master),
        base64.encode(master),
        b64Encode(vaultKey),
        base64.encode(vaultKey),
        _carolId,
        _bobId,
        'A message from Carol',
        '🙈',
        'archived',
        'muted',
        'pinned',
        'starred',
        'Starred',
      ];
      for (final needle in needles) {
        expect(text, isNot(contains(needle)), reason: needle);
      }
    });

    test('in pieces is the same text as in one piece', () {
      final messages = [
        for (var i = 0; i < 300; i++)
          _message(i + 1, outgoing: i.isEven, text: 'line $i'),
      ];
      final pieces = _PieceSink();
      ChatExport.writePlain(
        pieces,
        contactName: 'Bob',
        exportedAt: _exportedAt,
        messages: messages,
      );
      expect(pieces.pieces.join(), plain(messages));
      expect(
        pieces.pieces,
        hasLength(messages.length + 1),
        reason: 'the header, then one write per message',
      );
    });

    test('the labels replace the English words', () {
      final text = plain(
        _bobChat(),
        labels: const ChatExportLabels(
          you: 'Yo',
          deleted: 'Borrado',
          forwarded: 'Reenviado',
        ),
      );
      expect(text, contains('[2023-11-14T22:13:20Z] Yo: Hi Bob'));
      expect(text, contains('Yo: Borrado'));
      expect(text, contains('    Reenviado'));
    });
  });
}

/// The plain text of [_bobChat] with the English labels.
const _bobPlainText = '''
Bob
Exported 2026-10-10T12:00:00Z

[2023-11-14T22:13:20Z] Bob: Hello from Bob

[2023-11-14T22:13:20Z] You: Hi Bob
    Reactions: 👍 (Bob)
    Delivered 2023-11-14T22:13:20Z
    Read 2023-11-14T22:13:21Z

[2023-11-14T22:13:20Z] You: Replying
    Reply to: "Hello from Bob"

[2023-11-14T22:13:20Z] You: Edited text
    Edited 2023-11-14T22:13:20Z

[2023-11-14T22:13:20Z] Bob: Forwarded text
    Reactions: ❤️ (You), 😂 (Bob)
    Forwarded

[2023-11-14T22:13:20Z] You: File: report.pdf (5120 bytes)

[2023-11-14T22:13:20Z] You: Message deleted
''';
