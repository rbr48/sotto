import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/update_check.dart';
import 'package:sotto/core/version.dart';

void main() {
  UpdateChecker checker(String body) => UpdateChecker(
    endpoint: Uri.parse('https://releases.test/latest'),
    fetch: (_) async => body,
  );

  test('the version constant matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version: (\S+)',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1)!.split('+').first;
    expect(sottoVersion, version, reason: 'update lib/core/version.dart');
  });

  test('versions compare by number', () {
    expect(UpdateChecker.compareVersions('0.1.10', '0.1.9'), 1);
    expect(UpdateChecker.compareVersions('0.2.0', '0.10.0'), -1);
    expect(UpdateChecker.compareVersions('1.0.0+5', '1.0.0'), 0);
  });

  test('a newer release is offered with its page', () async {
    final update = await checker(
      '{"tag_name":"v0.1.3","html_url":"https://github.com/x/releases/tag/v0.1.3",'
      '"draft":false,"prerelease":false}',
    ).check(current: '0.1.2');
    expect(update?.version, '0.1.3');
    expect(update?.url.toString(), 'https://github.com/x/releases/tag/v0.1.3');
    expect(update?.canInstallInApp, isFalse);
  });

  test('a release with windows asset extracts asset download info', () async {
    final update = await checker(
      '{"tag_name":"v0.2.1","html_url":"https://github.com/x/releases/tag/v0.2.1",'
      '"draft":false,"prerelease":false,'
      '"assets":[{"name":"sotto-windows-x64-setup.exe","size":12345,'
      '"browser_download_url":"https://github.com/x/setup.exe"}]}',
    ).check(current: '0.2.0');
    expect(update?.version, '0.2.1');
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      expect(update?.canInstallInApp, isTrue);
      expect(update?.assetName, 'sotto-windows-x64-setup.exe');
      expect(update?.assetSize, 12345);
      expect(update?.assetUrl.toString(), 'https://github.com/x/setup.exe');
    }
  });

  test(
    'the same or an older release, pre-releases and errors: nothing',
    () async {
      const same = '{"tag_name":"v0.1.2","html_url":"https://x"}';
      expect(await checker(same).check(current: '0.1.2'), isNull);
      expect(
        await checker(
          '{"tag_name":"v0.2.0","html_url":"https://x","prerelease":true}',
        ).check(current: '0.1.2'),
        isNull,
      );
      expect(await checker('not json').check(current: '0.1.2'), isNull);
      expect(
        await UpdateChecker(
          disabled: true,
          fetch: (_) async => same,
        ).check(current: '0.0.1'),
        isNull,
        reason: 'switched off in this build',
      );
    },
  );
}
