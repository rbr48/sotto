import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../call/call_manager.dart';
import '../crypto/encoding.dart';
import '../crypto/identity.dart';
import '../crypto/identity_store.dart';

/// One call in the history. Stored on this device only.
@immutable
class CallRecord {
  const CallRecord({
    required this.id,
    required this.name,
    this.peer,
    this.guest = false,
    required this.outgoing,
    required this.video,
    required this.startedAt,
    this.connectedAt,
    required this.endedAt,
    required this.endReason,
    this.autoAnswered = false,
    this.note = '',
  });

  final String id;

  /// Who it was, as known when the call ended (contact name, guest name, or
  /// "Unknown caller").
  final String name;

  /// The other person's keys (to call back or add as a contact). `null` for
  /// guests, whose keys exist only for one visit.
  final PublicIdentity? peer;
  final bool guest;
  final bool outgoing;
  final bool video;
  final DateTime startedAt;
  final DateTime? connectedAt;
  final DateTime endedAt;
  final CallEndReason endReason;
  final bool autoAnswered;

  /// The professional's private session note.
  final String note;

  /// Talk time, if the call connected.
  Duration? get duration =>
      connectedAt == null ? null : endedAt.difference(connectedAt!);

  bool get missed => endReason == CallEndReason.missed;

  CallRecord withNote(String note) => CallRecord(
    id: id,
    name: name,
    peer: peer,
    guest: guest,
    outgoing: outgoing,
    video: video,
    startedAt: startedAt,
    connectedAt: connectedAt,
    endedAt: endedAt,
    endReason: endReason,
    autoAnswered: autoAnswered,
    note: note,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (peer case final peer?) ...{
      'sign': b64Encode(peer.signKey),
      'box': b64Encode(peer.boxKey),
    },
    'guest': guest,
    'out': outgoing,
    'video': video,
    'start': startedAt.millisecondsSinceEpoch,
    'conn': connectedAt?.millisecondsSinceEpoch,
    'end': endedAt.millisecondsSinceEpoch,
    'reason': endReason.name,
    'auto': autoAnswered,
    'note': note,
  };

  static CallRecord fromJson(Map<String, dynamic> json) {
    DateTime time(Object? ms) =>
        DateTime.fromMillisecondsSinceEpoch(ms as int, isUtc: true);
    return CallRecord(
      id: json['id'] as String,
      name: json['name'] as String,
      peer: json['sign'] == null
          ? null
          : PublicIdentity(
              signKey: b64Decode(json['sign'] as String),
              boxKey: b64Decode(json['box'] as String),
            ),
      guest: json['guest'] as bool? ?? false,
      outgoing: json['out'] as bool,
      video: json['video'] as bool,
      startedAt: time(json['start']),
      connectedAt: json['conn'] == null ? null : time(json['conn']),
      endedAt: time(json['end']),
      endReason: CallEndReason.values.byName(json['reason'] as String),
      autoAnswered: json['auto'] as bool? ?? false,
      note: json['note'] as String? ?? '',
    );
  }
}

/// Call history and session notes, kept in the vault and deleted
/// automatically after the chosen number of days.
class CallHistory extends ChangeNotifier {
  CallHistory(this._store, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const String storageKey = 'sotto.history.v1';

  /// Retention choices in days; 0 = don't keep history, `null` = forever.
  static const List<int?> retentionChoices = [0, 7, 30, 90, null];
  static const int defaultRetentionDays = 30;
  static const int maxEntries = 1000;

  final SecretStore _store;
  final DateTime Function() _clock;
  final List<CallRecord> _entries = [];
  int? _retentionDays = defaultRetentionDays;

  /// Newest first.
  List<CallRecord> get entries => List.unmodifiable(_entries);

  int? get retentionDays => _retentionDays;

  CallRecord? find(String id) => _entries.where((e) => e.id == id).firstOrNull;

  Future<void> load() async {
    _entries.clear();
    final stored = await _store.read(storageKey);
    if (stored != null) {
      try {
        final json = jsonDecode(stored) as Map<String, dynamic>;
        _retentionDays = json.containsKey('days')
            ? json['days'] as int?
            : defaultRetentionDays;
        for (final e in json['entries'] as List<dynamic>) {
          _entries.add(CallRecord.fromJson(e as Map<String, dynamic>));
        }
        _entries.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      } catch (_) {
        // Unreadable history: start empty.
      }
    }
    if (_purge()) await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    await _store.write(
      storageKey,
      jsonEncode({
        'days': _retentionDays,
        'entries': [for (final e in _entries) e.toJson()],
      }),
    );
  }

  /// Removes entries older than the retention period. Returns whether
  /// anything was removed.
  bool _purge() {
    final before = _entries.length;
    final days = _retentionDays;
    if (days != null) {
      final cutoff = _clock().subtract(Duration(days: days));
      _entries.removeWhere((e) => e.endedAt.isBefore(cutoff) || days == 0);
    }
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    return _entries.length != before;
  }

  /// Applies the retention period now (the app also calls this daily).
  Future<void> purge() async {
    if (_purge()) await _save();
  }

  Future<void> add(CallRecord record) async {
    if (_retentionDays == 0) return;
    _entries
      ..removeWhere((e) => e.id == record.id)
      ..insert(0, record);
    _purge();
    await _save();
  }

  Future<void> setNote(String id, String note) async {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    _entries[index] = _entries[index].withNote(note.trim());
    await _save();
  }

  Future<void> remove(String id) async {
    _entries.removeWhere((e) => e.id == id);
    await _save();
  }

  Future<void> clear() async {
    _entries.clear();
    await _save();
  }

  Future<void> setRetentionDays(int? days) async {
    _retentionDays = days;
    _purge();
    await _save();
  }
}

/// Who the other person in a call is, for the history.
typedef PeerDescriber = ({String name, bool guest}) Function(
  PublicIdentity peer,
);

/// Turns call state changes into history entries.
class CallRecorder {
  CallRecorder({
    required this.history,
    required this.describePeer,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final CallHistory history;
  final PeerDescriber describePeer;
  final DateTime Function() _clock;

  String? _callId;
  DateTime? _startedAt;
  DateTime? _connectedAt;

  /// The entry written for the most recent call (to attach a note).
  String? lastRecordId;

  /// Call with every state change of the call manager.
  Future<void> observe(CallState state) async {
    final callId = state.callId;
    if (callId == null) return;
    if (state.active && callId != _callId) {
      _callId = callId;
      _startedAt = _clock().toUtc();
      _connectedAt = null;
    }
    if (callId != _callId) return;
    if (state.phase == CallPhase.connected) {
      _connectedAt ??= _clock().toUtc();
    }
    if (state.phase == CallPhase.ended && state.peer != null) {
      final peer = state.peer!;
      final who = describePeer(peer);
      final record = CallRecord(
        id: callId,
        name: who.name,
        peer: who.guest ? null : peer,
        guest: who.guest,
        outgoing: state.outgoing,
        video: state.video,
        startedAt: _startedAt ?? _clock().toUtc(),
        connectedAt: _connectedAt,
        endedAt: _clock().toUtc(),
        endReason: state.endReason ?? CallEndReason.failed,
        autoAnswered: state.autoAnswered && !who.guest,
      );
      _callId = null;
      lastRecordId = history.retentionDays == 0 ? null : callId;
      await history.add(record);
    }
  }
}
