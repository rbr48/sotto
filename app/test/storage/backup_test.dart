import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sotto/crypto/sotto_crypto.dart';
import 'package:sotto/storage/backup.dart';

void main() {
  late SodiumSumo sodium;
  setUpAll(
    () async => sodium = SottoCrypto.passwordHashing(await SottoCrypto.init())!,
  );

  // Cheap parameters keep the tests fast; the defaults are tested once.
  String create(String passphrase, {int ops = 1, int mem = 8 << 20}) =>
      Backup.create(
        sodium,
        passphrase: passphrase,
        masterSecret: Uint8List.fromList(List.generate(32, (i) => i)),
        values: {'sotto.contacts.v1': '[Priya]'},
        now: DateTime.utc(2026, 10, 7),
        opsLimit: ops,
        memLimit: mem,
      );

  test('round trip with the default Argon2id cost', () {
    final text = Backup.create(
      sodium,
      passphrase: 'correct horse battery',
      masterSecret: Uint8List(32)..fillRange(0, 32, 7),
      values: {'k': 'v'},
    );
    expect(text, isNot(contains('"k"')));
    final json = jsonDecode(text) as Map<String, dynamic>;
    expect(json['kdf'], containsPair('alg', 'argon2id13'));
    expect(json['kdf'], containsPair('ops', Backup.defaultOpsLimit));
    expect(json['kdf'], containsPair('mem', Backup.defaultMemLimit));

    final opened = Backup.open(sodium, '  $text\n', 'correct horse battery');
    expect(opened.masterSecret, everyElement(7));
    expect(opened.values, {'k': 'v'});
  });

  test('wrong passphrase, tampering and changed parameters are rejected', () {
    final text = create('a long passphrase');
    expect(Backup.open(sodium, text, 'a long passphrase').values, {
      'sotto.contacts.v1': '[Priya]',
    });
    expect(
      () => Backup.open(sodium, text, 'a long passphrasE'),
      throwsA(_problem(BackupProblem.wrongPassphrase)),
    );

    final json = jsonDecode(text) as Map<String, dynamic>;
    final data = base64Url.decode(base64Url.normalize(json['data'] as String));
    data[5] ^= 1;
    final tampered = {
      ...json,
      'data': base64Url.encode(data).replaceAll('=', ''),
    };
    expect(
      () => Backup.open(sodium, jsonEncode(tampered), 'a long passphrase'),
      throwsA(_problem(BackupProblem.wrongPassphrase)),
    );

    // Lowering the cost in the header breaks the authenticated header.
    final cheaper = {
      ...json,
      'kdf': {...json['kdf'] as Map<String, dynamic>, 'mem': 16 << 20},
    };
    expect(
      () => Backup.open(sodium, jsonEncode(cheaper), 'a long passphrase'),
      throwsA(_problem(BackupProblem.wrongPassphrase)),
    );
  });

  test('rejects things that are not backups and absurd parameters', () {
    for (final text in ['', 'hello', '{}', '[1]', '{"sotto":"backup"}']) {
      expect(
        () => Backup.open(sodium, text, 'whatever passphrase'),
        throwsA(isA<BackupException>()),
        reason: text,
      );
    }
    final json =
        jsonDecode(create('a long passphrase')) as Map<String, dynamic>;
    expect(
      () => Backup.open(sodium, jsonEncode({...json, 'v': 2}), 'x'),
      throwsA(_problem(BackupProblem.unsupportedVersion)),
    );
    final huge = {
      ...json,
      'kdf': {...json['kdf'] as Map<String, dynamic>, 'mem': 1 << 40},
    };
    expect(
      () => Backup.open(sodium, jsonEncode(huge), 'a long passphrase'),
      throwsA(_problem(BackupProblem.notABackup)),
    );
  });

  test('short passphrases are refused; generated ones are long', () {
    expect(
      () => create('short'),
      throwsA(_problem(BackupProblem.weakPassphrase)),
    );
    final generated = Backup.generatePassphrase(sodium);
    expect(
      generated,
      matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{5}-){4}[0-9A-HJKMNP-TV-Z]{5}$')),
    );
    expect(Backup.generatePassphrase(sodium), isNot(generated));
  });
}

Matcher _problem(BackupProblem problem) =>
    isA<BackupException>().having((e) => e.problem, 'problem', problem);
