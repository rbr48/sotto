import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/desktop/single_instance.dart';

void main() {
  test('a second start shows the first and does not run', () async {
    final dir = await Directory.systemTemp.createTemp('sotto-instance');
    addTearDown(() => dir.delete(recursive: true));

    // A second process: the lock is per process.
    final script = File('${dir.path}/second.dart')
      ..writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final file = await File('\${args[0]}/instance.lock').open(mode: FileMode.append);
  try {
    await file.lock(FileLock.exclusive);
    stdout.write('first');
  } on FileSystemException {
    await File('\${args[0]}/instance.show').writeAsString('x');
    stdout.write('second');
  }
}
''');

    final first = await SingleInstance.claim(dir);
    expect(first, isNotNull);
    var activated = 0;
    SingleInstance.onActivate = () => activated++;

    final result = await Process.run('dart', [script.path, dir.path]);
    expect(result.stdout, 'second');
    for (var i = 0; i < 50 && activated == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(activated, greaterThan(0));

    await first!.release();
    final again = await Process.run('dart', [script.path, dir.path]);
    expect(again.stdout, 'first', reason: 'free again after the first quits');
  }, testOn: 'linux');
}
