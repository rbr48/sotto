import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/ui/export_dialog.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sotto-export-file');
    path = '${dir.path}/sotto-chat.sottochat';
  });

  tearDown(() => dir.delete(recursive: true));

  test(
    'a finished export replaces the earlier file, with no temporary file left',
    () async {
      await File(path).writeAsString('an earlier export');

      await writeExportFile(path, (file) async {
        file.write('one, ');
        await file.flush();
        file.write('two');
      });

      expect(await File(path).readAsString(), 'one, two');
      expect(await File('$path.part').exists(), isFalse);
    },
  );

  test(
    'a write that fails keeps the earlier export and leaves no partial file',
    () async {
      await File(path).writeAsString('an earlier export');

      await expectLater(
        writeExportFile(path, (file) async {
          file.write('partial');
          await file.flush();
          throw StateError('disk full');
        }),
        throwsStateError,
      );

      expect(await File(path).readAsString(), 'an earlier export');
      expect(await File('$path.part').exists(), isFalse);
    },
  );

  test('a write that fails with no earlier export creates no file', () async {
    await expectLater(
      writeExportFile(path, (file) async {
        file.write('partial');
        throw StateError('disk full');
      }),
      throwsStateError,
    );

    expect(await File(path).exists(), isFalse);
    expect(await File('$path.part').exists(), isFalse);
  });
}
