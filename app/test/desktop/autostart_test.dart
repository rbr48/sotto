import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/desktop/autostart.dart';

void main() {
  test('Linux: the entry lives in the XDG config folder', () {
    expect(
      Autostart.linuxEntryPath({'HOME': '/home/meera'}),
      '/home/meera/.config/autostart/sotto.desktop',
    );
    expect(
      Autostart.linuxEntryPath({
        'HOME': '/home/meera',
        'XDG_CONFIG_HOME': '/tmp/cfg',
      }),
      '/tmp/cfg/autostart/sotto.desktop',
    );
  });

  test('Linux: starts this executable hidden, path quoted', () {
    final entry = Autostart.linuxEntry(r'/opt/my apps/sotto $1/sotto');
    expect(entry, startsWith('[Desktop Entry]\n'));
    expect(entry, contains('Type=Application\n'));
    expect(entry, contains(r'Exec="/opt/my apps/sotto \$1/sotto" --hidden'));
  });

  test('Windows: the Run value starts this executable hidden', () {
    expect(
      Autostart.windowsCommand(r'C:\Users\Meera\Sotto\sotto.exe'),
      r'"C:\Users\Meera\Sotto\sotto.exe" --hidden',
    );
  });
}
