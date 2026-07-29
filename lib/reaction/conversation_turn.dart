/// One turn in the shared gesture/voice conversation history (spec Section
/// 4.4: "voice and image share the same context"). Previously this history
/// was just a flat list of the device's own past replies — real chat-style
/// history needs both sides of each exchange, not just what the assistant
/// said, so the model can actually tell what it's replying to on a
/// follow-up rather than re-deriving it from a fresh image alone.
class ConversationTurn {
  final bool isUser;
  final String text;

  const ConversationTurn.user(this.text) : isUser = true;
  const ConversationTurn.assistant(this.text) : isUser = false;

  String get line => '${isUser ? 'User' : 'You'}: $text';
}
