import 'event_log.dart';

/// The diagnostic report a user can copy and send when something doesn't
/// work. The user sees all of it before copying, and nothing is sent by
/// the app. It holds states and settings, never names, contacts, call
/// partners, links, IDs or keys.
abstract final class DiagnosticReport {
  static String build({
    required String version,
    required String platform,
    required Map<String, Object?> facts,
    required List<({DateTime at, String event})> events,
    required DateTime now,
  }) {
    final out = StringBuffer()
      ..writeln('Sotto diagnostic report')
      ..writeln('Created: ${_time(now)}')
      ..writeln('Version: $version')
      ..writeln('Platform: $platform')
      ..writeln();
    for (final MapEntry(:key, :value) in facts.entries) {
      if (value != null) out.writeln('$key: $value');
    }
    out
      ..writeln()
      ..writeln('Recent events (UTC):');
    if (events.isEmpty) out.writeln('  (none)');
    for (final entry in events) {
      out.writeln('  ${_time(entry.at)}  ${entry.event}');
    }
    out
      ..writeln()
      ..writeln(
        'This report contains no names, contacts, call partners, links or keys.',
      );
    return out.toString();
  }

  static String _time(DateTime t) =>
      t.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+'), '');

  /// The events of [EventLog.instance].
  static List<({DateTime at, String event})> get recentEvents =>
      EventLog.instance.entries;
}
