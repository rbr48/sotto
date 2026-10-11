import 'chat_manager.dart';
import 'chat_session.dart';

/// A message that just arrived from a contact, for the notifications. It holds
/// only the sender's name and whether that chat is open on screen: never the
/// text (`docs/MESSAGING_PLAN.md`, "Decisions").
class ChatArrival {
  const ChatArrival({required this.senderName, required this.viewing});

  /// The arrival that [event] reports, or null when it is not a new message.
  ///
  /// [nameOf] gives the name of a contact by Sotto ID, and "" for anyone who
  /// is not a contact, so a stranger is never named. [isViewing] says whether
  /// the chat, or the group, is open on screen.
  ///
  /// A group message is named by its author alone, never by the group: the
  /// group's name does not reach the lock screen (D14).
  static ChatArrival? of(
    ChatManagerEvent event, {
    required String Function(String id) nameOf,
    required bool Function(String scope) isViewing,
  }) {
    if (event case ChatUpdate(
      :final contact,
      :final group,
      event: MessageReceived(:final message),
    )) {
      final sender = group == null ? contact : message.authorId;
      return ChatArrival(
        senderName: sender == null ? '' : nameOf(sender),
        viewing: isViewing(contact),
      );
    }
    return null;
  }

  /// The contact's name as this device has it ("" if it is unknown).
  final String senderName;

  /// Whether the chat with this contact is open on screen.
  final bool viewing;
}
