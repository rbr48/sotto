import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/crypto/encoding.dart';

String _id(int n) => b64Encode(List<int>.filled(16, n));

/// A well-formed SHA-256 digest: 64 lowercase hex characters.
const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// [count] copies of the character with code point [codePoint].
String _rep(int codePoint, int count) =>
    String.fromCharCodes(List<int>.filled(count, codePoint));

/// A file offer frame as it arrives on the wire. [changes] replace fields of
/// a valid offer.
String _offer([Map<String, Object?> changes = const {}]) => jsonEncode({
  't': 'file.offer',
  'id': _id(10),
  'name': 'document.pdf',
  'size': 100,
  'mime': 'application/pdf',
  'sha256': _sha,
  'chunks': 1,
  ...changes,
});

/// The reason [raw] is refused, or null if it is accepted.
String? _refusal(String raw) {
  try {
    ChatFrames.decode(raw);
    return null;
  } on ChatFrameException catch (e) {
    return e.reason;
  }
}

void main() {
  group('frames round-trip', () {
    test('every frame type encodes and decodes to itself', () {
      final frames = <ChatFrame>[
        const HelloFrame(),
        MessageFrame(id: _id(1), ts: 1700000000000, text: 'Hello'),
        AckFrame(id: _id(1)),
        const ByeFrame(),
      ];
      for (final frame in frames) {
        final decoded = ChatFrames.decode(ChatFrames.encode(frame));
        expect(decoded.runtimeType, frame.runtimeType);
      }
      final message = ChatFrames.decode(
        ChatFrames.encode(MessageFrame(id: _id(2), ts: 5, text: 'Salaam')),
      ) as MessageFrame;
      expect(message.id, _id(2));
      expect(message.ts, 5);
      expect(message.text, 'Salaam');

      final typing = ChatFrames.decode(
        ChatFrames.encode(const TypingFrame(typing: true)),
      ) as TypingFrame;
      expect(typing.typing, true);

      final read = ChatFrames.decode(
        ChatFrames.encode(ReadFrame(ids: [_id(1), _id(2)])),
      ) as ReadFrame;
      expect(read.ids, [_id(1), _id(2)]);
    });

    test('the encoding is the documented JSON', () {
      expect(ChatFrames.encode(const HelloFrame()), '{"t":"hello","v":1}');
      expect(ChatFrames.encode(const ByeFrame()), '{"t":"bye"}');
      expect(
        ChatFrames.encode(AckFrame(id: _id(3))),
        '{"t":"ack","id":"${_id(3)}"}',
      );
      expect(
        ChatFrames.encode(const TypingFrame(typing: true)),
        '{"t":"typing","typing":true}',
      );
      expect(
        ChatFrames.encode(ReadFrame(ids: [_id(1), _id(2)])),
        '{"t":"read","ids":["${_id(1)}","${_id(2)}"]}',
      );
    });
  });

  group('rejects malformed frames', () {
    void rejects(String raw, String reason) {
      expect(
        () => ChatFrames.decode(raw),
        throwsA(
          isA<ChatFrameException>().having((e) => e.reason, 'reason', reason),
        ),
        reason: raw,
      );
    }

    test('not JSON, or not an object', () {
      rejects('not json', 'malformed');
      rejects('[1,2]', 'malformed');
      rejects('"hello"', 'malformed');
    });

    test('unknown type', () {
      rejects('{"t":"video"}', 'unknown');
      rejects('{}', 'unknown');
    });

    test('another protocol version', () {
      rejects('{"t":"hello","v":2}', 'version');
      rejects('{"t":"hello"}', 'version');
    });

    test('message ids must be 16 random bytes', () {
      rejects('{"t":"ack","id":"short"}', 'malformed');
      rejects('{"t":"ack","id":"${_id(1)}="}', 'malformed');
      rejects('{"t":"ack","id":7}', 'malformed');
      rejects('{"t":"msg","id":"${_id(1)}","ts":0,"text":"x"}', 'malformed');
    });

    test('timestamps must be positive whole numbers', () {
      rejects('{"t":"msg","id":"${_id(1)}","ts":"1","text":"x"}', 'malformed');
      rejects('{"t":"msg","id":"${_id(1)}","ts":1.5,"text":"x"}', 'malformed');
    });

    test('text must be a string of at most 4000 characters', () {
      rejects('{"t":"msg","id":"${_id(1)}","ts":1,"text":5}', 'malformed');
      final long = 'a' * (maxTextChars + 1);
      rejects('{"t":"msg","id":"${_id(1)}","ts":1,"text":"$long"}', 'too-long');
    });

    test('frames over 16 KiB are refused before they are read', () {
      final huge = 'a' * (maxFrameBytes + 1);
      rejects(
        '{"t":"msg","id":"${_id(1)}","ts":1,"text":"$huge"}',
        'too-large',
      );
    });
  });

  test(
    'text of exactly 4000 characters is accepted, even at the frame limit',
    () {
      // Every character a 4-byte emoji: the largest text a frame can carry.
      final text = List.filled(maxTextChars, '\u{1F600}').join();
      final raw = ChatFrames.encode(
        MessageFrame(id: _id(1), ts: 1, text: text),
      );
      final decoded = ChatFrames.decode(raw) as MessageFrame;
      expect(decoded.text.runes.length, maxTextChars);
    },
  );

  test('encoding refuses a frame over 16 KiB', () {
    final text = List.filled(maxTextChars, '\u{1F600}').join() + '"' * 4000;
    expect(
      () => ChatFrames.encode(MessageFrame(id: _id(1), ts: 1, text: text)),
      throwsA(isA<ChatFrameException>()),
    );
  });

  group('cleanText', () {
    test('removes control characters but keeps line breaks and tabs', () {
      expect(
        ChatFrames.cleanText('a\u0000b\u0007c\u007Fd\u0085e\nf\tg'),
        'abcde\nf\tg',
      );
    });

    test('removes characters that change the reading direction', () {
      // Right-to-left override, and a left-to-right isolate.
      expect(ChatFrames.cleanText('pay\u202E 100\u2066'), 'pay 100');
    });

    test('keeps Arabic and Bangla text, and trims the ends', () {
      expect(ChatFrames.cleanText('  مرحبا  '), 'مرحبا');
      expect(ChatFrames.cleanText('ঁ নমস্কার​'), 'ঁ নমস্কার​');
    });
  });

  group('ids', () {
    test('newId makes 16 random bytes, unpadded base64url', () {
      final a = ChatFrames.newId(Random(1));
      final b = ChatFrames.newId(Random(2));
      expect(a.length, 22);
      expect(ChatFrames.isId(a), isTrue);
      expect(a, isNot(b));
      expect(b64Decode(a).length, 16);
    });

    test('isId accepts only the canonical form', () {
      expect(ChatFrames.isId(_id(9)), isTrue);
      expect(ChatFrames.isId(_id(9).substring(1)), isFalse);
      expect(ChatFrames.isId('${_id(9)}='), isFalse);
      expect(ChatFrames.isId(null), isFalse);
      expect(ChatFrames.isId(12), isFalse);
    });
  });

  group('file frames', () {
    test('file frame types encode and decode correctly', () {
      final offer = FileOfferFrame(
        id: _id(10),
        name: 'document.pdf',
        size: 1024,
        mime: 'application/pdf',
        sha256: _sha,
        chunks: 1,
      );
      final accept = FileAcceptFrame(id: _id(10));
      final decline = FileDeclineFrame(id: _id(10));
      final done = FileDoneFrame(id: _id(10));
      final ack = FileAckFrame(id: _id(10));
      final cancel = FileCancelFrame(id: _id(10), reason: 'user-cancelled');

      final decodedOffer =
          ChatFrames.decode(ChatFrames.encode(offer)) as FileOfferFrame;
      expect(decodedOffer.id, _id(10));
      expect(decodedOffer.name, 'document.pdf');
      expect(decodedOffer.size, 1024);
      expect(decodedOffer.mime, 'application/pdf');
      expect(decodedOffer.sha256, _sha);
      expect(decodedOffer.chunks, 1);

      final decodedAccept =
          ChatFrames.decode(ChatFrames.encode(accept)) as FileAcceptFrame;
      expect(decodedAccept.id, _id(10));

      final decodedDecline =
          ChatFrames.decode(ChatFrames.encode(decline)) as FileDeclineFrame;
      expect(decodedDecline.id, _id(10));

      final decodedDone =
          ChatFrames.decode(ChatFrames.encode(done)) as FileDoneFrame;
      expect(decodedDone.id, _id(10));

      final decodedAck =
          ChatFrames.decode(ChatFrames.encode(ack)) as FileAckFrame;
      expect(decodedAck.id, _id(10));

      final decodedCancel =
          ChatFrames.decode(ChatFrames.encode(cancel)) as FileCancelFrame;
      expect(decodedCancel.id, _id(10));
      expect(decodedCancel.reason, 'user-cancelled');
    });

    test('a valid file offer is accepted, with its name cleaned', () {
      final offer =
          ChatFrames.decode(_offer({'name': 'a\tb/c.pdf'})) as FileOfferFrame;
      expect(offer.name, 'ab_c.pdf');
      expect(offer.size, 100);
      expect(offer.sha256, _sha);
    });

    test('a blocked name decodes, so the session can decline it', () {
      final offer =
          ChatFrames.decode(_offer({'name': 'malware.exe'})) as FileOfferFrame;
      expect(offer.name, 'malware.exe');
      expect(ChatFrames.isBlockedFileType(offer.name), isTrue);
    });

    test('size must be from 1 to the largest file size', () {
      expect(_refusal(_offer({'size': 0, 'chunks': 1})), 'malformed');
      expect(_refusal(_offer({'size': -5, 'chunks': 1})), 'malformed');
      expect(_refusal(_offer({'size': 1.0})), 'malformed');
      expect(_refusal(_offer({'size': 'big'})), 'malformed');
      final tooBig = maxFileSizeNative + 1;
      expect(
        _refusal(
          _offer({'size': tooBig, 'chunks': (tooBig / fileChunkSize).ceil()}),
        ),
        'malformed',
      );
    });

    test('chunks must be the number of 16 KiB pieces the size needs', () {
      expect(_refusal(_offer({'chunks': 0})), 'malformed');
      expect(_refusal(_offer({'size': 100, 'chunks': 2})), 'malformed');
      expect(
        _refusal(_offer({'size': fileChunkSize + 1, 'chunks': 1})),
        'malformed',
      );
      expect(_refusal(_offer({'size': 1, 'chunks': 2})), 'malformed');
    });

    test(
      'a 1-byte file, and one of exactly fileChunkSize bytes, are accepted',
      () {
        expect(_refusal(_offer({'size': 1, 'chunks': 1})), isNull);
        expect(_refusal(_offer({'size': fileChunkSize, 'chunks': 1})), isNull);
        expect(
          _refusal(_offer({'size': fileChunkSize + 1, 'chunks': 2})),
          isNull,
        );
        expect(
          _refusal(
            _offer({
              'size': maxFileSizeNative,
              'chunks': maxFileSizeNative ~/ fileChunkSize,
            }),
          ),
          isNull,
        );
      },
    );

    test('sha256 must be 64 lowercase hex characters', () {
      expect(_refusal(_offer({'sha256': 'abc123hash'})), 'malformed');
      expect(_refusal(_offer({'sha256': ''})), 'malformed');
      expect(_refusal(_offer({'sha256': _sha.toUpperCase()})), 'malformed');
      expect(_refusal(_offer({'sha256': '${_sha}0'})), 'malformed');
      expect(
        _refusal(_offer({'sha256': 'g${_sha.substring(1)}'})),
        'malformed',
      );
      expect(_refusal(_offer()), isNull);
    });

    test('mime is at most 128 characters, and name 1 to 512 characters', () {
      expect(_refusal(_offer({'mime': 'a' * 128})), isNull);
      expect(_refusal(_offer({'mime': 'a' * 129})), 'malformed');
      expect(_refusal(_offer({'name': ''})), 'malformed');
      expect(_refusal(_offer({'name': 'a' * 512})), isNull);
      expect(_refusal(_offer({'name': 'a' * 513})), 'malformed');
    });

    test('a name blocked only after cleaning is flagged, and a colon is not '
        'a stream name', () {
      final stream = ChatFrames.decode(
        _offer({'name': r'setup.exe::$DATA'}),
      ) as FileOfferFrame;
      expect(stream.name, r'setup.exe__$DATA');
      expect(stream.blocked, isFalse);

      final hidden = ChatFrames.decode(
        _offer({'name': '${'x' * 100}.exe${' ' * 40}x'}),
      ) as FileOfferFrame;
      expect(hidden.blocked, isTrue);

      final plain = ChatFrames.decode(_offer()) as FileOfferFrame;
      expect(plain.blocked, isFalse);
    });

    test('encodeChunk and decodeChunk round trip', () {
      final fileId = _id(15);
      final payload = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
      final encoded = ChatFrames.encodeChunk(
        fileId: fileId,
        chunkIndex: 42,
        payload: payload,
      );
      expect(encoded.length, 20 + payload.length);

      final decoded = ChatFrames.decodeChunk(encoded);
      expect(decoded.fileId, fileId);
      expect(decoded.chunkIndex, 42);
      expect(decoded.payload, payload);

      expect(
        () => ChatFrames.decodeChunk(Uint8List(19)),
        throwsA(isA<ChatFrameException>()),
      );
    });
  });

  group('cleanFileName', () {
    test('removes path separators and leading dots', () {
      expect(
        ChatFrames.cleanFileName('../secret/passwords.txt'),
        '_secret_passwords.txt',
      );
      expect(ChatFrames.cleanFileName(r'..\..\config.json'), '__config.json');
      expect(ChatFrames.cleanFileName('...hidden.doc'), 'hidden.doc');
    });

    test('defaults empty or dot-only filenames to "file"', () {
      expect(ChatFrames.cleanFileName(''), 'file');
      expect(ChatFrames.cleanFileName('...'), 'file');
    });

    test('prefixes reserved Windows names with file_', () {
      expect(ChatFrames.cleanFileName('CON.txt'), 'file_CON.txt');
      expect(ChatFrames.cleanFileName('nul'), 'file_nul');
      expect(ChatFrames.cleanFileName('prn.pdf'), 'file_prn.pdf');
      expect(ChatFrames.cleanFileName('COM1.dat'), 'file_COM1.dat');
    });

    test('truncates long names to 120 bytes, keeping the extension', () {
      expect(ChatFrames.cleanFileName('${'a' * 150}.pdf'), '${'a' * 116}.pdf');
      expect(
        ChatFrames.cleanFileName('${'x' * 200}.docx'),
        '${'x' * 115}.docx',
      );
    });

    test('counts UTF-8 bytes, and never splits a character', () {
      // Two bytes a letter: 58 letters fill the 116 bytes left by ".pdf".
      expect(
        ChatFrames.cleanFileName('${_rep(0xE9, 100)}.pdf'),
        '${_rep(0xE9, 58)}.pdf',
      );
      // Three bytes a character: 38 of them, then ".txt", is 118 bytes.
      expect(
        ChatFrames.cleanFileName('${_rep(0x6587, 80)}.txt'),
        '${_rep(0x6587, 38)}.txt',
      );
      // Four bytes a character: 29 of them, then ".jpg", is 120 bytes.
      expect(
        ChatFrames.cleanFileName('${_rep(0x1F600, 50)}.jpg'),
        '${_rep(0x1F600, 29)}.jpg',
      );
    });

    test('an extension longer than 40 bytes is cut to 40', () {
      final cleaned = ChatFrames.cleanFileName('${'a' * 70}.${'b' * 60}');
      expect(cleaned, '${'a' * 70}.${'b' * 39}');
      expect(utf8.encode(cleaned).length, lessThanOrEqualTo(120));
    });

    test('the file_ prefix of a reserved name counts toward the cap', () {
      final cleaned = ChatFrames.cleanFileName('CON.${'x' * 115}.pdf');
      expect(cleaned.startsWith('file_CON.'), isTrue);
      expect(cleaned.endsWith('.pdf'), isTrue);
      expect(utf8.encode(cleaned).length, lessThanOrEqualTo(120));
    });

    test('reserved names with a trailing space are prefixed too', () {
      expect(ChatFrames.cleanFileName('CON .txt'), 'file_CON .txt');
    });

    test('never keeps a control character, a slash or a backslash', () {
      expect(ChatFrames.cleanFileName('a\tb\nc\x00d\\e/f.txt'), 'abcd_e_f.txt');
      expect(ChatFrames.cleanFileName('\x00\x01\t'), 'file');
    });

    test('cleaning a cleaned name changes nothing', () {
      for (final name in [
        'a/b\\c.txt',
        '${'x' * 200}.pdf',
        'nul.${_rep(0xE9, 150)}',
        '${_rep(0x1F600, 50)}.jpg',
        '\x00 name \x07.exe',
      ]) {
        final once = ChatFrames.cleanFileName(name);
        expect(ChatFrames.cleanFileName(once), once, reason: name);
      }
    });

    test('a reserved name left bare by the cut is prefixed too', () {
      // The cut leaves "CON" and spaces, which trim to CON.
      expect(ChatFrames.cleanFileName('CON${' ' * 200}x.txt'), 'file_CON.txt');
      expect(ChatFrames.cleanFileName('CON${' ' * 130}x'), 'file_CON');
    });

    test('the other reserved device names are prefixed as well', () {
      expect(ChatFrames.cleanFileName('COM0.txt'), 'file_COM0.txt');
      expect(ChatFrames.cleanFileName('LPT0.txt'), 'file_LPT0.txt');
      expect(ChatFrames.cleanFileName('COM¹.txt'), 'file_COM¹.txt');
      expect(ChatFrames.cleanFileName('lpt².dat'), 'file_lpt².dat');
      expect(ChatFrames.cleanFileName(r'CONIN$.txt'), r'file_CONIN$.txt');
      expect(ChatFrames.cleanFileName(r'conout$.txt'), r'file_conout$.txt');
    });

    test('colons become underscores, so no stream name can be written', () {
      expect(
        ChatFrames.cleanFileName(r'setup.exe::$DATA'),
        r'setup.exe__$DATA',
      );
      expect(
        ChatFrames.cleanFileName('Meeting 10:30.pdf'),
        'Meeting 10_30.pdf',
      );
    });

    test('invisible characters are removed, and nothing left is file', () {
      expect(ChatFrames.cleanFileName('\u200B\u200C\u200F\uFEFF'), 'file');
      expect(ChatFrames.cleanFileName('a\u200Bb\u202Ec.pdf'), 'abc.pdf');
    });

    test('an extension cut in the middle of spaces leaves none at the end', () {
      final once = ChatFrames.cleanFileName('${'x' * 10}.${' a' * 80}');
      expect(once.endsWith(' '), isFalse);
      expect(ChatFrames.cleanFileName(once), once);
    });

    test('any name cleans to a safe name that cleaning leaves alone', () {
      final random = Random(20261009);
      const pieces = [
        'a',
        'Z',
        '.',
        '..',
        ' ',
        '\\',
        '/',
        ':',
        '\t',
        '\n',
        '\u0000',
        '\u007F',
        '\u200B',
        '\u202E',
        '\u2066',
        '\uFEFF',
        '\uD800',
        'é',
        '文',
        '😀',
        r'$',
        'CON',
        'nul',
        'COM',
        '1',
        '¹',
        'exe',
        'pdf',
      ];
      final reserved = RegExp(
        r'^(CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³]'
        r'|CONIN\$|CONOUT\$)$',
        caseSensitive: false,
      );
      bool unsafe(int rune) =>
          rune < 0x20 ||
          (rune >= 0x7F && rune <= 0x9F) ||
          (rune >= 0x200B && rune <= 0x200F) ||
          (rune >= 0x202A && rune <= 0x202E) ||
          (rune >= 0x2066 && rune <= 0x2069) ||
          rune == 0xFEFF ||
          (rune >= 0xD800 && rune <= 0xDFFF) ||
          rune == 0x2F ||
          rune == 0x5C ||
          rune == 0x3A;

      for (var i = 0; i < 3000; i++) {
        final raw = StringBuffer();
        final length = random.nextInt(200);
        for (var j = 0; j < length; j++) {
          raw.write(pieces[random.nextInt(pieces.length)]);
        }
        final once = ChatFrames.cleanFileName(raw.toString());
        final reason = 'case $i';

        expect(once, isNotEmpty, reason: reason);
        expect(
          utf8.encode(once).length,
          lessThanOrEqualTo(maxFileNameBytes),
          reason: reason,
        );
        expect(once.runes.any(unsafe), isFalse, reason: reason);
        expect(once.startsWith('.'), isFalse, reason: reason);
        expect(once.endsWith(' '), isFalse, reason: reason);
        expect(
          reserved.hasMatch(once.split('.').first.trimRight()),
          isFalse,
          reason: reason,
        );
        expect(ChatFrames.cleanFileName(once), once, reason: reason);
      }
    });
  });

  group('isBlockedFileType', () {
    test('identifies executable, script, and installer files', () {
      expect(ChatFrames.isBlockedFileType('virus.exe'), isTrue);
      expect(ChatFrames.isBlockedFileType('script.bat'), isTrue);
      expect(ChatFrames.isBlockedFileType('script.cmd'), isTrue);
      expect(ChatFrames.isBlockedFileType('script.sh'), isTrue);
      expect(ChatFrames.isBlockedFileType('script.ps1'), isTrue);
      expect(ChatFrames.isBlockedFileType('script.vbs'), isTrue);
      expect(ChatFrames.isBlockedFileType('app.apk'), isTrue);
      expect(ChatFrames.isBlockedFileType('installer.msi'), isTrue);
      expect(ChatFrames.isBlockedFileType('setup.dmg'), isTrue);
    });

    test('permits safe documents and media files', () {
      expect(ChatFrames.isBlockedFileType('document.pdf'), isFalse);
      expect(ChatFrames.isBlockedFileType('photo.png'), isFalse);
      expect(ChatFrames.isBlockedFileType('photo.jpg'), isFalse);
      expect(ChatFrames.isBlockedFileType('video.mp4'), isFalse);
      expect(ChatFrames.isBlockedFileType('notes.txt'), isFalse);
      expect(ChatFrames.isBlockedFileType('archive.zip'), isFalse);
    });

    test('ignores case', () {
      expect(ChatFrames.isBlockedFileType('SETUP.EXE'), isTrue);
      expect(ChatFrames.isBlockedFileType('Setup.Exe'), isTrue);
      expect(ChatFrames.isBlockedFileType('Report.PDF'), isFalse);
    });

    test('ignores trailing dots and spaces', () {
      expect(ChatFrames.isBlockedFileType('setup.exe.'), isTrue);
      expect(ChatFrames.isBlockedFileType('setup.exe..'), isTrue);
      expect(ChatFrames.isBlockedFileType('run.EXE '), isTrue);
      expect(ChatFrames.isBlockedFileType('run.exe . '), isTrue);
      expect(ChatFrames.isBlockedFileType('report.pdf.'), isFalse);
    });

    test('ignores control and invisible characters inside the name', () {
      expect(ChatFrames.isBlockedFileType('setup.exe\x00'), isTrue);
      expect(ChatFrames.isBlockedFileType('set\x07up.ex\x01e'), isTrue);
      expect(ChatFrames.isBlockedFileType('setup.exe\x7F'), isTrue);
      expect(
        ChatFrames.isBlockedFileType('setup.ex${String.fromCharCode(0x200B)}e'),
        isTrue,
      );
    });

    test('takes the last path segment, on either kind of slash', () {
      expect(ChatFrames.isBlockedFileType(r'C:\Users\me\setup.exe'), isTrue);
      expect(ChatFrames.isBlockedFileType('folder/setup.exe'), isTrue);
      expect(ChatFrames.isBlockedFileType('setup.exe/readme.txt'), isFalse);
      expect(ChatFrames.isBlockedFileType(r'folder.exe\readme.txt'), isFalse);
    });

    test('judges a double extension by its last part', () {
      expect(ChatFrames.isBlockedFileType('report.pdf.exe'), isTrue);
      expect(ChatFrames.isBlockedFileType('invoice.pdf.scr'), isTrue);
      expect(ChatFrames.isBlockedFileType('my.exe.backup'), isFalse);
    });

    test('a right-to-left override does not hide the extension', () {
      final override = String.fromCharCode(0x202E);
      expect(ChatFrames.isBlockedFileType('invoice${override}fdp.exe'), isTrue);
      expect(ChatFrames.isBlockedFileType('photo${override}gpj'), isFalse);
    });

    test('a name with no dot is not blocked', () {
      expect(ChatFrames.isBlockedFileType('exe'), isFalse);
      expect(ChatFrames.isBlockedFileType('setup'), isFalse);
      expect(ChatFrames.isBlockedFileType('exe.'), isFalse);
    });

    test('blocks each type it lists, in any case', () {
      const types = [
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
        '.html',
        '.htm',
        '.xhtml',
        '.shtml',
        '.mht',
        '.mhtml',
        '.svg',
        '.svgz',
        '.hta',
        '.pif',
        '.gadget',
        '.reg',
        '.inf',
        '.url',
        '.scf',
        '.wsf',
        '.wsh',
        '.vb',
        '.vbe',
        '.jse',
        '.msc',
        '.cpl',
        '.msp',
        '.mst',
        '.chm',
        '.pkg',
        '.command',
        '.ipa',
        '.xap',
        '.crx',
        '.docm',
        '.dotm',
        '.xlsm',
        '.xlsb',
        '.pptm',
        '.iso',
        '.img',
        '.vhd',
        '.vhdx',
        // Windows app packages, update packages and script components.
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
        // Office add-ins, macro-enabled templates and slide shows.
        '.xlam',
        '.xla',
        '.ppam',
        '.ppsm',
        '.potm',
        '.xltm',
      ];
      for (final ext in types) {
        expect(ChatFrames.isBlockedFileType('file$ext'), isTrue, reason: ext);
        expect(
          ChatFrames.isBlockedFileType('FILE${ext.toUpperCase()}'),
          isTrue,
          reason: ext,
        );
      }
    });

    test('allows ordinary documents, images, archives and media', () {
      for (final name in [
        'contract.docx',
        'sheet.xlsx',
        'deck.pptx',
        'photo.jpeg',
        'page.webp',
        'song.mp3',
        'readme.md',
      ]) {
        expect(ChatFrames.isBlockedFileType(name), isFalse, reason: name);
      }
    });

    test('the final extension decides, even when a colon comes before it', () {
      // The colon is not split on: the name is judged by its last dot.
      expect(ChatFrames.isBlockedFileType('report.pdf:setup.exe'), isTrue);
      expect(ChatFrames.isBlockedFileType(r'setup.exe::$DATA'), isFalse);
      expect(
        ChatFrames.isBlockedFileType('payload.exe:Zone.Identifier'),
        isFalse,
      );
      expect(ChatFrames.isBlockedFileType('setup.exe:readme.txt'), isFalse);
    });

    test('a colon does not block a name whose final extension is allowed', () {
      expect(ChatFrames.isBlockedFileType('Meeting 10:30.pdf'), isFalse);
      expect(ChatFrames.isBlockedFileType('notes.txt:stream'), isFalse);
      expect(
        ChatFrames.isBlockedFileType('Notes for acme.com: final.pdf'),
        isFalse,
      );
      expect(
        ChatFrames.isBlockedFileType('Summary of app.js: draft.pdf'),
        isFalse,
      );
    });

    test('a name blocked only once cleaned is found by cleaning it', () {
      // The cut to 120 bytes leaves ".exe", and the spaces after it are cut.
      final name = '${'x' * 100}.exe${' ' * 40}x';
      expect(ChatFrames.isBlockedFileType(name), isFalse);
      expect(
        ChatFrames.isBlockedFileType(ChatFrames.cleanFileName(name)),
        isTrue,
      );
    });
  });
}
