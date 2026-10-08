import 'package:flutter/foundation.dart';

/// What happened recently (relay connection, call states, errors), kept
/// in memory for the diagnostic report only: never stored, never sent.
///
/// Entries must not contain names, Sotto IDs, links, keys or call
/// partners: only states, routes and error messages.
class EventLog {
  EventLog({this.capacity = 150, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static final EventLog instance = EventLog();

  final int capacity;
  final DateTime Function() _clock;
  final _entries = <({DateTime at, String event})>[];

  List<({DateTime at, String event})> get entries =>
      List.unmodifiable(_entries);

  void add(String event) {
    _entries.add((at: _clock().toUtc(), event: event));
    if (_entries.length > capacity) _entries.removeAt(0);
    if (kDebugMode) debugPrint('[sotto] $event');
  }

  @visibleForTesting
  void clear() => _entries.clear();
}
