import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/call/trusted_callers.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

void main() {
  late Sodium sodium;
  setUpAll(() async => sodium = await SottoCrypto.init());

  PublicIdentity person() => Identity.generate(sodium).publicIdentity;

  test(
    'off by default: nobody is auto-answered, even trusted callers',
    () async {
      final trusted = TrustedCallers(MemorySecretStore());
      final wife = person();
      await trusted.trust(TrustedCaller(identity: wife, name: 'Priya'));
      expect(trusted.enabled, isFalse);
      expect(trusted.decide(wife, videoCall: true), isNull);
    },
  );

  test('when on: trusted callers after the delay, voice only unless video is allowed', () async {
    final trusted = TrustedCallers(MemorySecretStore());
    final wife = person();
    await trusted.trust(TrustedCaller(identity: wife, name: 'Priya'));
    await trusted.setEnabled(true);

    final voice = trusted.decide(wife, videoCall: true)!;
    expect(
      voice.delay,
      const Duration(seconds: TrustedCallers.defaultDelaySeconds),
    );
    expect(voice.video, isFalse);

    await trusted.setAllowVideo(wife, true);
    await trusted.setDelaySeconds(2);
    final video = trusted.decide(wife, videoCall: true)!;
    expect(video.video, isTrue);
    expect(video.delay, const Duration(seconds: 2));
    expect(trusted.decide(wife, videoCall: false)!.video, isFalse);
  });

  test('strangers ring normally, and so does someone who copies only the signing key', () async {
    final trusted = TrustedCallers(MemorySecretStore());
    final wife = person();
    await trusted.trust(TrustedCaller(identity: wife, name: 'Priya'));
    await trusted.setEnabled(true);
    expect(trusted.decide(person(), videoCall: true), isNull);
    final sameSignKey = PublicIdentity(
      signKey: wife.signKey,
      boxKey: person().boxKey,
    );
    expect(trusted.decide(sameSignKey, videoCall: true), isNull);
  });

  test('removing a caller and the delay limits', () async {
    final trusted = TrustedCallers(MemorySecretStore());
    final wife = person();
    await trusted.trust(TrustedCaller(identity: wife, name: 'Priya'));
    await trusted.setEnabled(true);
    await trusted.setDelaySeconds(99);
    expect(trusted.delaySeconds, TrustedCallers.maxDelaySeconds);
    await trusted.setDelaySeconds(-3);
    expect(trusted.delaySeconds, 0);
    await trusted.remove(wife);
    expect(trusted.decide(wife, videoCall: true), isNull);
  });

  test(
    'settings survive a restart; unreadable settings keep auto-answer off',
    () async {
      final secrets = MemorySecretStore();
      final first = TrustedCallers(secrets);
      final wife = person();
      await first.trust(
        TrustedCaller(identity: wife, name: 'Priya', allowVideo: true),
      );
      await first.setEnabled(true);
      await first.setDelaySeconds(3);

      final reloaded = TrustedCallers(secrets);
      await reloaded.load();
      expect(reloaded.enabled, isTrue);
      expect(reloaded.delaySeconds, 3);
      expect(reloaded.find(wife)?.name, 'Priya');
      expect(reloaded.find(wife)?.allowVideo, isTrue);

      await secrets.write(TrustedCallers.storageKey, '{broken');
      final broken = TrustedCallers(secrets);
      await broken.load();
      expect(broken.enabled, isFalse);
      expect(broken.callers, isEmpty);
    },
  );
}
