import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/ui/chat_page.dart';

({String name, Future<Uint8List> Function() read, String? mime}) _file(
  String name, {
  String? mime = 'text/plain',
}) => (
  name: name,
  read: () async => Uint8List.fromList(name.codeUnits),
  mime: mime,
);

void main() {
  test('every picked file is offered, in the order picked', () async {
    final offered = <String>[];
    final skipped = await sendPickedFiles(
      picked: [_file('a.txt'), _file('b.pdf'), _file('c.jpg', mime: null)],
      offer: (name, bytes, mime) async {
        offered.add('$name|$mime|${bytes.length}');
        return null;
      },
    );

    expect(skipped, isEmpty);
    expect(offered, [
      'a.txt|text/plain|5',
      'b.pdf|text/plain|5',
      'c.jpg|application/octet-stream|5',
    ]);
  });

  test('a blocked or refused file is skipped, and the rest still go', () async {
    final offered = <String>[];
    final skipped = await sendPickedFiles(
      picked: [
        _file('notes.txt'),
        _file('setup.EXE '),
        _file('broken.jpg'),
        _file('last.txt'),
      ],
      offer: (name, bytes, mime) async {
        if (name == 'broken.jpg') {
          throw ArgumentError('Image could not be read');
        }
        offered.add(name);
        return null;
      },
    );

    expect(offered, ['notes.txt', 'last.txt']);
    expect(skipped.map((s) => s.name), ['setup.EXE ', 'broken.jpg']);
    expect(skipped.first.error.toString(), contains('Blocked file type'));
  });

  test('a blocked file is never read', () async {
    var reads = 0;
    await sendPickedFiles(
      picked: [
        (
          name: 'run.bat',
          read: () async {
            reads++;
            return Uint8List(1);
          },
          mime: null,
        ),
      ],
      offer: (name, bytes, mime) async => null,
    );

    expect(reads, 0);
  });

  test('only the first $maxFilesPerPick files of a pick are sent', () async {
    final offered = <String>[];
    await sendPickedFiles(
      picked: [for (var i = 0; i < maxFilesPerPick + 3; i++) _file('f$i.txt')],
      offer: (name, bytes, mime) async {
        offered.add(name);
        return null;
      },
    );

    expect(offered, [for (var i = 0; i < maxFilesPerPick; i++) 'f$i.txt']);
  });

  test('the screen is refreshed after each file that went', () async {
    var refreshed = 0;
    await sendPickedFiles(
      picked: [_file('a.txt'), _file('b.exe'), _file('c.txt')],
      offer: (name, bytes, mime) async => null,
      onSent: () async => refreshed++,
    );

    expect(refreshed, 2);
  });
}
