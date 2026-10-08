/// The apps to download: always the newest release on GitHub (the file names
/// stay the same from one release to the next).
abstract final class Downloads {
  static const _latest =
      'https://github.com/rbr48/sotto/releases/latest/download/';

  static final android = Uri.parse('${_latest}sotto-android.apk');

  /// The installer (Start menu entry, uninstaller).
  static final windows = Uri.parse('${_latest}sotto-windows-x64-setup.exe');

  /// Runs on most distributions; a .deb and a tar.gz are on the release page.
  static final linux = Uri.parse('${_latest}sotto-linux-x86_64.AppImage');
}
