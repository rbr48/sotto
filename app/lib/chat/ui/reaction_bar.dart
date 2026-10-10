import 'package:flutter/material.dart';

import '../../core/l10n/app_localizations.dart';
import 'chat_tokens.dart';
import 'emoji_picker_panel.dart';

/// The reactions under a message, and the quick choices for adding one.
///
/// [reactions] is keyed `me` (yours) or `peer`. Tapping a reaction you set
/// removes it, by sending the empty emoji. Tapping the other person's adds
/// the same emoji as yours. While [choosing] (the React item was picked), the
/// quick emoji are shown, and the more button opens the full picker.
class ReactionBar extends StatelessWidget {
  const ReactionBar({
    super.key,
    required this.reactions,
    required this.peerName,
    required this.choosing,
    required this.onReact,
  });

  final Map<String, String> reactions;

  /// The contact's name, for the screen reader label of their reaction.
  final String peerName;

  final bool choosing;

  /// Called with the emoji to set, or with '' to remove your own reaction.
  final ValueChanged<String> onReact;

  /// The emoji offered first. Anything else is in the full picker.
  static const quickEmoji = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty && !choosing) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 2),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final entry in reactions.entries)
            _Chip(
              emoji: entry.value,
              who: entry.key == 'me' ? l10n.chatYou : peerName,
              mine: entry.key == 'me',
              onTap: () => onReact(entry.key == 'me' ? '' : entry.value),
            ),
          if (choosing) ...[
            for (final emoji in quickEmoji)
              _Chip(
                emoji: emoji,
                who: null,
                mine: reactions['me'] == emoji,
                onTap: () => onReact(emoji),
              ),
            IconButton(
              tooltip: l10n.chatEmojiTooltip,
              style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.add_reaction_outlined),
              onPressed: () => _pickMore(context),
            ),
          ],
        ],
      ),
    );
  }

  /// The full picker, in a sheet. Returns the emoji chosen, if any.
  Future<void> _pickMore(BuildContext context) async {
    final tokens = ChatTokens.of(context);
    final emoji = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: EmojiPickerPanel(
          tokens: tokens,
          onEmojiSelected: (emoji) => Navigator.pop(sheetContext, emoji),
          onBackspace: null,
        ),
      ),
    );
    if (emoji != null) onReact(emoji);
  }
}

/// One reaction, or one quick choice. [who] names whose reaction it is; null
/// for a choice, which is announced as the emoji alone.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.emoji,
    required this.who,
    required this.mine,
    required this.onTap,
  });

  final String emoji;
  final String? who;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final l10n = AppLocalizations.of(context);
    return Semantics(
      button: true,
      selected: mine,
      label: who == null ? emoji : l10n.chatReactionSemantics(emoji, who!),
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Center(
            widthFactor: 1,
            child: Container(
              constraints: const BoxConstraints(minWidth: 40),
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: mine ? tokens.sendFill : tokens.pillFill,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: tokens.receivedBorder, width: 0.8),
              ),
              child: Text(
                emoji,
                style: const TextStyle(
                  fontSize: 18,
                  fontFamilyFallback: [
                    'Apple Color Emoji',
                    'Segoe UI Emoji',
                    'Noto Color Emoji',
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
