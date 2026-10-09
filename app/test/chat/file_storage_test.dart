import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/file_storage.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

String _id(int n) => b64Encode(List<int>.filled(16, n));

Uint8List _text(String text) => Uint8List.fromList(utf8.encode(text));

ChatMessage _file(int n, {required String name, String? stored, String? key}) =>
    ChatMessage(
      id: _id(n),
      contactId: 'bob',
      outgoing: false,
      ts: 1700000000000 + n,
      text: '',
      state: ChatState.received,
      fileId: _id(200 + n),
      fileName: name,
      fileSize: 10,
      fileStatus: 'completed',
      filePath: stored,
      fileKey: key,
    );

Matcher _reason(String reason) =>
    isA<ReceivedFileException>().having((e) => e.reason, 'reason', reason);

final _storedName = RegExp(r'^[0-9a-f]{32}$');

void main() {
  late Sodium sodium;
  late Directory root;
  late Directory received;
  late ReceivedFileStore files;

  setUpAll(() async {
    sodium = await SottoCrypto.init();
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('sotto_files_');
    received = Directory('${root.path}/received');
    files = ReceivedFileStore(sodium: sodium, directory: () async => received);
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('ReceivedFileStore', () {
    test('a saved file reads back as the same bytes', () async {
      final saved = await files.save(_text('the plan'));

      expect(saved.name, matches(_storedName));
      expect(
        await files.read(name: saved.name, key: saved.key),
        _text('the plan'),
      );
    });

    test('the file on disk is not readable and names nothing', () async {
      final saved = await files.save(_text('quarterly plan, do not share'));

      final onDisk = File('${received.path}/${saved.name}').readAsBytesSync();
      expect(
        utf8.decode(onDisk, allowMalformed: true),
        isNot(contains('quarterly plan')),
      );
      expect(received.listSync().map((e) => e.uri.pathSegments.last), [
        saved.name,
      ]);
    });

    test('a wrong key is refused as damaged', () async {
      final saved = await files.save(_text('x'));
      final other = await files.save(_text('y'));

      await expectLater(
        files.read(name: saved.name, key: other.key),
        throwsA(_reason('damaged')),
      );
    });

    test('a changed file is refused as damaged', () async {
      final saved = await files.save(_text('original contents'));
      final path = '${received.path}/${saved.name}';
      final bytes = File(path).readAsBytesSync();
      bytes[bytes.length - 1] ^= 0x01;
      File(path).writeAsBytesSync(bytes);

      await expectLater(
        files.read(name: saved.name, key: saved.key),
        throwsA(_reason('damaged')),
      );
    });

    test('a file that is gone is reported as missing', () async {
      final saved = await files.save(_text('gone'));
      await files.remove(saved.name);

      await expectLater(
        files.read(name: saved.name, key: saved.key),
        throwsA(_reason('missing')),
      );
    });

    test('a name that is not one of ours is never opened', () async {
      final saved = await files.save(_text('secret'));

      await expectLater(
        files.read(name: '../${saved.name}', key: saved.key),
        throwsA(_reason('missing')),
      );
    });

    test(
      'removing is quiet for files that are gone and for the web marker',
      () async {
        final saved = await files.save(_text('bye'));

        await files.remove('web:abc');
        await files.remove(null);
        await files.remove(saved.name);
        await files.remove(saved.name);
      },
    );

    test('eraseAll removes every received file', () async {
      await files.save(_text('a'));
      await files.save(_text('b'));

      await files.eraseAll();

      expect(received.existsSync(), isFalse);
    });
  });

  group('ChatStore with received files', () {
    test('deleting a message deletes its encrypted file', () async {
      final store = ChatStore(MemorySecretStore(), files: files);
      final saved = await files.save(_text('gone soon'));
      await store.add(
        _file(1, name: 'a.txt', stored: saved.name, key: saved.key),
      );

      await store.deleteMessage('bob', _id(1));

      expect(await store.find('bob', _id(1)), isNull);
      expect(File('${received.path}/${saved.name}').existsSync(), isFalse);
    });

    test(
      'readFile gives back the file for the message that holds its key',
      () async {
        final store = ChatStore(MemorySecretStore(), files: files);
        final saved = await files.save(_text('hello'));
        await store.add(
          _file(2, name: 'hello.txt', stored: saved.name, key: saved.key),
        );

        final message = (await store.find('bob', _id(2)))!;
        expect(await store.readFile(message), _text('hello'));
      },
    );

    test('a message without a key cannot read its file', () async {
      final store = ChatStore(MemorySecretStore(), files: files);
      final message = _file(3, name: 'x.txt', stored: 'abcd');

      await expectLater(store.readFile(message), throwsA(_reason('missing')));
    });

    test(
      'plaintext files from earlier versions are moved into the store',
      () async {
        final legacyDir = Directory('${received.path}/legacy-file-id')
          ..createSync(recursive: true);
        final legacy = File('${legacyDir.path}/old.txt')
          ..writeAsBytesSync(_text('old plaintext'));
        final store = ChatStore(MemorySecretStore(), files: files);
        await store.add(_file(4, name: 'old.txt', stored: legacy.path));

        await store.encryptLegacyFiles();

        final moved = (await store.find('bob', _id(4)))!;
        expect(moved.filePath, matches(_storedName));
        expect(moved.fileKey, isNotNull);
        expect(legacy.existsSync(), isFalse);
        expect(legacyDir.existsSync(), isFalse);
        expect(await store.readFile(moved), _text('old plaintext'));
      },
    );

    test('a legacy file that cannot be moved is left as it is', () async {
      final store = ChatStore(MemorySecretStore(), files: files);
      final missing = '${root.path}/never-there/old.txt';
      await store.add(_file(5, name: 'old.txt', stored: missing));

      await store.encryptLegacyFiles();

      final message = (await store.find('bob', _id(5)))!;
      expect(message.filePath, missing);
      expect(message.fileKey, isNull);
    });
  });
}
