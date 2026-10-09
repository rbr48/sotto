/// A message that just arrived from a contact, for the notifications. It holds
/// only the sender's name and whether that chat is open on screen: never the
/// text (`docs/MESSAGING_PLAN.md`, "Decisions").
class ChatArrival {
  const ChatArrival({required this.senderName, required this.viewing});

  /// The contact's name as this device has it ("" if it is unknown).
  final String senderName;

  /// Whether the chat with this contact is open on screen.
  final bool viewing;
}
