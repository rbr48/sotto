/// Remembers recently seen message nonces so a captured message can't be
/// delivered twice. Entries are only needed while a message would still pass
/// the timestamp check, so they expire after [ttl].
///
/// When the guard is full of entries that have not expired, it refuses new
/// keys rather than forgetting old ones. Forgetting would let a captured
/// message be accepted again; refusing drops only the newcomer.
class ReplayGuard {
  ReplayGuard({required this.ttl, this.maxEntries = 50000});

  final Duration ttl;

  /// Upper bound on memory.
  final int maxEntries;

  // Map literals keep insertion order, so the first entry is the oldest, and
  // with a clock that never runs backwards, the first to expire.
  final _seen = <String, DateTime>{};

  /// The latest time seen. A clock set back can't make an entry expire early
  /// (or late), so the entries stay in expiry order.
  DateTime? _latest;

  int get length => _seen.length;

  /// Records [key] and returns `true` if it was not seen within [ttl] and
  /// there is room for it. Returns `false` for a repeat, and for a new key
  /// while the guard is full.
  bool checkAndRecord(String key, DateTime now) {
    final at = _monotonic(now);
    _prune(at);
    if (_seen.containsKey(key)) return false;
    if (_seen.length >= maxEntries) return false;
    _seen[key] = at.add(ttl);
    return true;
  }

  DateTime _monotonic(DateTime now) {
    final latest = _latest;
    if (latest != null && !now.isAfter(latest)) return latest;
    return _latest = now;
  }

  void _prune(DateTime now) {
    while (_seen.isNotEmpty && !_seen.values.first.isAfter(now)) {
      _seen.remove(_seen.keys.first);
    }
  }
}
