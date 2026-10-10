import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/chat_frames.dart';
import 'package:sotto/chat/chat_store.dart';
import 'package:sotto/chat/ui/message_menu.dart';

final _sent = DateTime(2026, 10, 9, 12);

ChatMessage _text({
  bool outgoing = true,
  bool deleted = false,
  String text = 'Salaam',
}) => ChatMessage(
  id: ChatFrames.newId(),
  contactId: 'bob',
  outgoing: outgoing,
  ts: _sent.millisecondsSinceEpoch,
  text: deleted ? '' : text,
  state: ChatState.delivered,
  deletedForAll: deleted,
);

ChatMessage _file() => ChatMessage(
  id: ChatFrames.newId(),
  contactId: 'bob',
  outgoing: true,
  ts: _sent.millisecondsSinceEpoch,
  text: 'report.pdf',
  state: ChatState.delivered,
  fileId: ChatFrames.newId(),
  fileName: 'report.pdf',
  fileSize: 10,
  fileMime: 'application/pdf',
  fileStatus: 'completed',
  filePath: 'web:report',
);

DateTime _after(Duration elapsed) => _sent.add(elapsed);

void main() {
  group('the edit and delete windows', () {
    test('an edit is allowed up to 15 minutes after the message was sent', () {
      final mine = _text();
      expect(
        canEdit(mine, _after(const Duration(minutes: 14, seconds: 59))),
        isTrue,
      );
      expect(canEdit(mine, _after(const Duration(minutes: 15))), isTrue);
      expect(
        canEdit(mine, _after(const Duration(minutes: 15, seconds: 1))),
        isFalse,
      );
      expect(
        canEdit(mine, _after(const Duration(minutes: 59, seconds: 59))),
        isFalse,
      );
      expect(
        canEdit(mine, _after(const Duration(hours: 1, seconds: 1))),
        isFalse,
      );
    });

    test('a delete for everyone is allowed up to an hour after the message was sent', () {
      final mine = _text();
      expect(
        canDeleteForEveryone(
          mine,
          _after(const Duration(minutes: 14, seconds: 59)),
        ),
        isTrue,
      );
      expect(
        canDeleteForEveryone(
          mine,
          _after(const Duration(minutes: 15, seconds: 1)),
        ),
        isTrue,
      );
      expect(
        canDeleteForEveryone(
          mine,
          _after(const Duration(minutes: 59, seconds: 59)),
        ),
        isTrue,
      );
      expect(
        canDeleteForEveryone(
          mine,
          _after(const Duration(hours: 1, seconds: 1)),
        ),
        isFalse,
      );
    });

    test('the windows are the ones the manager uses, not copies of them', () {
      final mine = _text();
      final justInside = _after(editWindow);
      final justOutside = _after(editWindow + const Duration(seconds: 1));
      expect(canEdit(mine, justInside), isTrue);
      expect(canEdit(mine, justOutside), isFalse);
      expect(canDeleteForEveryone(mine, _after(deleteWindow)), isTrue);
      expect(
        canDeleteForEveryone(
          mine,
          _after(deleteWindow + const Duration(seconds: 1)),
        ),
        isFalse,
      );
    });

    test('a message is never changed before it was sent', () {
      final mine = _text();
      final before = _sent.subtract(const Duration(seconds: 1));
      expect(canEdit(mine, before), isFalse);
      expect(canDeleteForEveryone(mine, before), isFalse);
    });

    test('a message from the other person cannot be edited or deleted', () {
      final theirs = _text(outgoing: false);
      final now = _after(const Duration(minutes: 1));
      expect(canEdit(theirs, now), isFalse);
      expect(canDeleteForEveryone(theirs, now), isFalse);
    });

    test('a deleted message cannot be edited or deleted again', () {
      final gone = _text(deleted: true);
      final now = _after(const Duration(minutes: 1));
      expect(canEdit(gone, now), isFalse);
      expect(canDeleteForEveryone(gone, now), isFalse);
    });

    test('a file cannot be edited, and cannot be deleted for everyone', () {
      final file = _file();
      final now = _after(const Duration(minutes: 1));
      expect(canEdit(file, now), isFalse);
      expect(canDeleteForEveryone(file, now), isFalse);
    });
  });

  group('the menu items', () {
    test('your own text, while the windows are open, offers every action', () {
      final now = _after(const Duration(minutes: 1));
      expect(messageActions(_text(), now), [
        MessageAction.react,
        MessageAction.reply,
        MessageAction.forward,
        MessageAction.copy,
        MessageAction.edit,
        MessageAction.deleteForEveryone,
        MessageAction.deleteForMe,
      ]);
    });

    test(
      'after 15 minutes the edit goes, and the delete for everyone stays',
      () {
        final now = _after(const Duration(minutes: 20));
        final actions = messageActions(_text(), now);
        expect(actions, isNot(contains(MessageAction.edit)));
        expect(actions, contains(MessageAction.deleteForEveryone));
      },
    );

    test('after an hour neither edit nor delete for everyone is offered', () {
      final now = _after(const Duration(hours: 2));
      final actions = messageActions(_text(), now);
      expect(actions, isNot(contains(MessageAction.edit)));
      expect(actions, isNot(contains(MessageAction.deleteForEveryone)));
      expect(actions, contains(MessageAction.deleteForMe));
    });

    test('the other person\'s text has no edit and no delete for everyone', () {
      final actions = messageActions(
        _text(outgoing: false),
        _after(const Duration(minutes: 1)),
      );
      expect(actions, [
        MessageAction.react,
        MessageAction.reply,
        MessageAction.forward,
        MessageAction.copy,
        MessageAction.deleteForMe,
      ]);
    });

    test('a file cannot be forwarded or edited', () {
      final actions = messageActions(
        _file(),
        _after(const Duration(minutes: 1)),
      );
      expect(actions, isNot(contains(MessageAction.forward)));
      expect(actions, isNot(contains(MessageAction.edit)));
      expect(actions, contains(MessageAction.reply));
      expect(actions, contains(MessageAction.deleteForMe));
    });

    test('a deleted message offers only delete for me', () {
      expect(
        messageActions(
          _text(deleted: true),
          _after(const Duration(minutes: 1)),
        ),
        [MessageAction.deleteForMe],
      );
    });
  });
}
