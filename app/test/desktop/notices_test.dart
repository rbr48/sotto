import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
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

  test('chat messages: nothing while the chat is open in front, otherwise a notice', () {
    ChatNoticeKind kind({
      bool notifications = true,
      bool showNames = false,
      bool inFront = false,
      bool viewing = false,
      bool locked = false,
    }) => NoticeRules.chatMessage(
      prefs: prefs.copyWith(notifications: notifications, showNames: showNames),
      inFront: inFront,
      viewing: viewing,
      locked: locked,
    );

    expect(
      kind(),
      ChatNoticeKind.anonymous,
      reason: 'in the background: no names by default',
    );
    expect(kind(inFront: true, viewing: true), ChatNoticeKind.none);
    expect(
      kind(inFront: true, viewing: false),
      ChatNoticeKind.anonymous,
      reason: 'another chat in front still gets a notice',
    );
    expect(kind(notifications: false), ChatNoticeKind.none);
    expect(kind(showNames: true), ChatNoticeKind.named);
    expect(
      kind(showNames: true, locked: true),
      ChatNoticeKind.anonymous,
      reason: 'no names while locked',
    );
  });

  test(
    'chat notices say who sent it only when names are chosen, never the text',
    () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      Notice? words(ChatNoticeKind kind, {String senderName = 'Meera Rao'}) =>
          NoticeRules.chatWords(kind: kind, senderName: senderName, l10n: l10n);

      final named = words(ChatNoticeKind.named)!;
      expect(named.title, 'New message from Meera Rao');
      expect(named.body, 'Open Sotto to read it.');

      final anonymous = words(ChatNoticeKind.anonymous)!;
      expect(anonymous.title, 'New message');
      expect(anonymous.toString(), isNot(contains('Meera')));

      expect(
        words(ChatNoticeKind.named, senderName: '')!.title,
        'New message',
        reason: 'a named notice with no name falls back to the anonymous one',
      );
      expect(words(ChatNoticeKind.none), isNull);
    },
  );
}
