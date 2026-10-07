/// Remembers recently seen message nonces so a captured message can't be
/// delivered twice. Entries are only needed while a message would still pass
/// the timestamp check, so they expire after [ttl].
class ReplayGuard {
  ReplayGuard({required this.ttl, this.maxEntries = 50000});

  final Duration ttl;

  /// Upper bound on memory. When full, the oldest entries are evicted.
  final int maxEntries;

  // Map literals keep insertion order, so the first entry is the oldest.
  final _seen = <String, DateTime>{};

  int get length => _seen.length;

  /// Records [key] and returns `true` if it was not seen within [ttl].
  bool checkAndRecord(String key, DateTime now) {
    _prune(now);
    if (_seen.containsKey(key)) return false;
    _seen[key] = now.add(ttl);
    while (_seen.length > maxEntries) {
      _seen.remove(_seen.keys.first);
    }
    return true;
  }

  void _prune(DateTime now) {
    while (_seen.isNotEmpty && !_seen.values.first.isAfter(now)) {
      _seen.remove(_seen.keys.first);
    }
  }
}
