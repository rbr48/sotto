import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'version.dart';

/// A newer release than this app.
@immutable
class UpdateInfo {
  const UpdateInfo({required this.version, required this.url});

  /// e.g. `0.1.3`.
  final String version;

  /// The release page, where the files are.
  final Uri url;
}

/// Asks the release page (GitHub Releases, unless the build says
/// otherwise) for the latest version. The native apps check at most once a
/// day, if the user leaves "Check for updates" on; the browser always gets
/// the current version from its server and never checks.
///
/// Only the release service is contacted; it sees this device's IP address
/// and nothing else.
class UpdateChecker {
  UpdateChecker({
    Uri? endpoint,
    bool disabled = false,
    Future<String> Function(Uri url)? fetch,
  }) : endpoint = disabled ? null : endpoint ?? defaultEndpoint,
       _fetch = fetch ?? _get;

  /// Builds for another repository (or none: empty) set `SOTTO_UPDATE_URL`.
  static final Uri? defaultEndpoint = () {
    const url = String.fromEnvironment(
      'SOTTO_UPDATE_URL',
      defaultValue: 'https://api.github.com/repos/rbr48/sotto/releases/latest',
    );
    return url.isEmpty ? null : Uri.parse(url);
  }();

  final Uri? endpoint;
  final Future<String> Function(Uri url) _fetch;

  /// The newer release, or `null` if this is the latest (or the check
  /// failed: it is tried again later).
  Future<UpdateInfo?> check({String current = sottoVersion}) async {
    final url = endpoint;
    if (url == null) return null;
    try {
      final json = jsonDecode(await _fetch(url)) as Map<String, dynamic>;
      if (json['draft'] == true || json['prerelease'] == true) return null;
      final tag = json['tag_name'] as String;
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      if (compareVersions(version, current) <= 0) return null;
      return UpdateInfo(
        version: version,
        url: Uri.parse(json['html_url'] as String),
      );
    } catch (e) {
      debugPrint('Update check failed: $e');
      return null;
    }
  }

  /// Compares `1.2.3` style versions (a `+build` part is ignored).
  static int compareVersions(String a, String b) {
    List<int> parts(String v) =>
        v.split('+').first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final x = parts(a);
    final y = parts(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d.sign;
    }
    return 0;
  }

  static Future<String> _get(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(url);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'Sotto/$sottoVersion');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        throw HttpException('status ${response.statusCode}');
      }
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }
}
