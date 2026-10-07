import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/call/call_manager.dart';
import 'package:sotto/crypto/sotto_crypto.dart';
import 'package:sotto/history/call_history.dart';

void main() {
  late Sodium sodium;
  setUpAll(() async => sodium = await SottoCrypto.init());

  var now = DateTime.utc(2026, 10, 7, 9);
  DateTime clock() => now;
  setUp(() => now = DateTime.utc(2026, 10, 7, 9));

  CallRecord record(String id, {required DateTime at, String note = ''}) =>
      CallRecord(
        id: id,
        name: 'Priya',
        outgoing: true,
        video: false,
        startedAt: at,
        endedAt: at.add(const Duration(minutes: 5)),
        endReason: CallEndReason.hungUp,
        note: note,
      );

  test('the recorder writes one entry per call with talk time', () async {
    final history = CallHistory(MemorySecretStore(), clock: clock);
    await history.load();
    final peer = Identity.generate(sodium).publicIdentity;
    final recorder = CallRecorder(
      history: history,
      describePeer: (_) => (name: 'Priya', guest: false),
      clock: clock,
    );
    final calling = CallState(
      phase: CallPhase.calling,
      peer: peer,
      callId: 'c1',
      outgoing: true,
    );
    await recorder.observe(calling);
    now = now.add(const Duration(seconds: 10));
    await recorder.observe(calling.copyWith(phase: CallPhase.connecting));
    now = now.add(const Duration(seconds: 2));
    await recorder.observe(calling.copyWith(phase: CallPhase.connected));
    now = now.add(const Duration(minutes: 3));
    await recorder.observe(
      calling.copyWith(phase: CallPhase.ended, endReason: CallEndReason.hungUp),
    );
    // A repeated "ended" state doesn't add a second entry.
    await recorder.observe(
      calling.copyWith(phase: CallPhase.ended, endReason: CallEndReason.hungUp),
    );

    expect(history.entries, hasLength(1));
    final entry = history.entries.single;
    expect(entry.name, 'Priya');
    expect(entry.peer, peer);
    expect(entry.outgoing, isTrue);
    expect(entry.duration, const Duration(minutes: 3));
    expect(recorder.lastRecordId, 'c1');

    // A missed call has no talk time; guests are stored without keys.
    final guestRecorder = CallRecorder(
      history: history,
      describePeer: (_) => (name: 'Asha (guest)', guest: true),
      clock: clock,
    );
    final incoming = CallState(
      phase: CallPhase.incoming,
      peer: peer,
      callId: 'c2',
      autoAnswered: true,
    );
    await guestRecorder.observe(incoming);
    await guestRecorder.observe(
      incoming.copyWith(
        phase: CallPhase.ended,
        endReason: CallEndReason.missed,
      ),
    );
    final missed = history.entries.first;
    expect(missed.missed, isTrue);
    expect(missed.duration, isNull);
    expect(missed.peer, isNull);
    expect(missed.guest, isTrue);
    expect(
      missed.autoAnswered,
      isFalse,
      reason: 'guest admissions are not auto-answers',
    );
  });

  test('notes, deletion and persistence', () async {
    final store = MemorySecretStore();
    final history = CallHistory(store, clock: clock);
    await history.load();
    await history.add(record('a', at: now.subtract(const Duration(hours: 2))));
    await history.add(record('b', at: now.subtract(const Duration(hours: 1))));
    expect(history.entries.map((e) => e.id), ['b', 'a']);
    await history.setNote('a', '  Follow up on Tuesday  ');

    final reloaded = CallHistory(store, clock: clock);
    await reloaded.load();
    expect(reloaded.find('a')!.note, 'Follow up on Tuesday');
    expect(reloaded.entries.map((e) => e.id), ['b', 'a']);
    await reloaded.remove('b');
    expect(reloaded.entries.map((e) => e.id), ['a']);
    await reloaded.clear();
    expect(reloaded.entries, isEmpty);
  });

  test(
    'auto-delete after the retention period; "don\'t keep" stores nothing',
    () async {
      final store = MemorySecretStore();
      final history = CallHistory(store, clock: clock);
      await history.load();
      expect(history.retentionDays, CallHistory.defaultRetentionDays);
      await history.add(
        record('old', at: now.subtract(const Duration(days: 40))),
      );
      expect(history.entries, isEmpty, reason: 'already past 30 days');
      await history.add(
        record('recent', at: now.subtract(const Duration(days: 6))),
      );
      await history.add(record('today', at: now));

      await history.setRetentionDays(7);
      expect(history.entries.map((e) => e.id), ['today', 'recent']);
      now = now.add(const Duration(days: 2));
      final reloaded = CallHistory(store, clock: clock);
      await reloaded.load();
      expect(reloaded.entries.map((e) => e.id), ['today']);

      await reloaded.setRetentionDays(null);
      await reloaded.add(
        record('ancient', at: now.subtract(const Duration(days: 999))),
      );
      expect(reloaded.entries, hasLength(2));

      await reloaded.setRetentionDays(0);
      expect(reloaded.entries, isEmpty);
      await reloaded.add(record('x', at: now));
      expect(reloaded.entries, isEmpty);
      expect(await store.read(CallHistory.storageKey), isNot(contains('"x"')));
    },
  );
}
