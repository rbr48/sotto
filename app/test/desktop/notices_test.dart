import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/desktop/notices.dart';

void main() {
  const prefs = DesktopPrefs();

  test('defaults: tray on, notifications on, names hidden', () {
    expect(prefs.keepInTray && prefs.notifications, isTrue);
    expect(prefs.showNames, isFalse);
    expect(DesktopPrefs.decode(null).showNames, isFalse);
    expect(DesktopPrefs.decode('{broken').notifications, isTrue);
    final changed = prefs.copyWith(keepInTray: false, showNames: true);
    final round = DesktopPrefs.decode(changed.encode());
    expect(round.keepInTray, isFalse);
    expect(round.showNames, isTrue);
  });

  test('knocks: only in the background; names only if chosen and unlocked', () {
    expect(
      NoticeRules.knock(
        guestName: 'Asha',
        prefs: prefs,
        inFront: true,
        locked: false,
      ),
      isNull,
    );
    expect(
      NoticeRules.knock(
        guestName: 'Asha',
        prefs: prefs,
        inFront: false,
        locked: false,
      ),
      const Notice(
        'A guest is waiting',
        'Someone knocked on your link. Open Sotto to admit them.',
      ),
    );
    final named = prefs.copyWith(showNames: true);
    expect(
      NoticeRules.knock(
        guestName: 'Asha',
        prefs: named,
        inFront: false,
        locked: false,
      )!.title,
      'Asha is waiting',
    );
    expect(
      NoticeRules.knock(
        guestName: 'Asha',
        prefs: named,
        inFront: false,
        locked: true,
      )!.title,
      'A guest is waiting',
    );
    expect(
      NoticeRules.knock(
        guestName: 'Asha',
        prefs: prefs.copyWith(notifications: false),
        inFront: false,
        locked: false,
      ),
      isNull,
    );
  });

  test('incoming calls', () {
    final named = prefs.copyWith(showNames: true);
    expect(
      NoticeRules.incomingCall(
        callerName: 'Priya',
        video: false,
        prefs: named,
        inFront: false,
        locked: false,
      ),
      const Notice('Incoming voice call', 'Priya'),
    );
    expect(
      NoticeRules.incomingCall(
        callerName: 'Priya',
        video: true,
        prefs: prefs,
        inFront: false,
        locked: false,
      ),
      const Notice('Incoming video call', 'Open Sotto to answer.'),
    );
    expect(
      NoticeRules.incomingCall(
        callerName: 'Priya',
        video: true,
        prefs: named,
        inFront: true,
        locked: false,
      ),
      isNull,
    );
  });

  test('Android ringing: always rings, a name only if chosen and unlocked', () {
    final call = NoticeRules.androidCall(
      callerName: 'Dr Rao',
      video: true,
      prefs: const DesktopPrefs(notifications: false),
      locked: false,
    );
    expect(call, const Notice('Incoming video call', 'Sotto'));
    expect(
      NoticeRules.androidCall(
        callerName: 'Dr Rao',
        video: false,
        prefs: const DesktopPrefs(showNames: true),
        locked: false,
      ),
      const Notice('Incoming voice call', 'Dr Rao'),
    );
    expect(
      NoticeRules.androidCall(
        callerName: 'Dr Rao',
        video: false,
        prefs: const DesktopPrefs(showNames: true),
        locked: true,
      ).body,
      'Sotto',
    );
  });

  test('start at login and ring when closed are kept', () {
    const defaults = DesktopPrefs();
    expect(defaults.startAtLogin, isFalse);
    expect(defaults.ringWhenClosed, isTrue);
    final changed = defaults.copyWith(
      startAtLogin: true,
      ringWhenClosed: false,
    );
    final round = DesktopPrefs.decode(changed.encode());
    expect(round.startAtLogin, isTrue);
    expect(round.ringWhenClosed, isFalse);
    // Stored before these existed.
    final old = DesktopPrefs.decode(
      '{"tray":true,"notify":true,"names":false}',
    );
    expect(old.startAtLogin, isFalse);
    expect(old.ringWhenClosed, isTrue);
  });
}
