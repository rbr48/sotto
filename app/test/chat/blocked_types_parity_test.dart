import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';

void main() {
  test('Android refuses exactly the types the app never shares', () {
    final kotlin = File(
      'android/app/src/main/kotlin/com/izhaanintellect/sotto/Files.kt',
    ).readAsStringSync();
    final start = kotlin.indexOf('private val BLOCKED_EXTENSIONS = setOf(');
    expect(start, greaterThan(-1), reason: 'Files.kt lists the blocked types');
    final end = kotlin.indexOf(')', start);
    final listed = RegExp(r'"([a-z0-9-]+)"')
        .allMatches(kotlin.substring(start, end))
        .map((m) => m.group(1)!)
        .toSet();
    final dart = ChatFrames.blockedExtensions
        .map((e) => e.substring(1))
        .toSet();
    expect(listed, dart);
  });

  test(
    'scripts and programs are blocked whatever the case, path or padding',
    () {
      for (final name in [
        'setup.exe',
        'notes.PY',
        'run.pyw',
        'tool.pl',
        'page.php',
        'deploy.rb',
        'install.bash',
        'launcher.desktop',
        'lib.so',
        'lib.dll',
        'Link.webloc',
        'report.docm',
        'disc.iso',
        'trailing.exe. ',
        'folder/../good.py',
      ]) {
        expect(ChatFrames.isBlockedFileType(name), isTrue, reason: name);
      }
      for (final name in ['photo.jpg', 'notes.txt', 'report.pdf', 'song.m4a']) {
        expect(ChatFrames.isBlockedFileType(name), isFalse, reason: name);
      }
    },
  );
}
