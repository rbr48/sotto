import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'avatar_helper.dart';
import 'l10n/app_localizations.dart';

/// How much a [NoticeCard] asks for attention.
enum NoticeTone { info, warning, success }

/// A notice with an icon, a title, a short explanation and an optional
/// action below it (never squeezed beside the text on a phone).
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.tone = NoticeTone.info,
  });

  final IconData icon;
  final String title;
  final Widget? body;
  final Widget? action;
  final NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final accent = switch (tone) {
      NoticeTone.info => scheme.primary,
      NoticeTone.warning =>
        dark ? const Color(0xFFF2B866) : const Color(0xFFB45309),
      NoticeTone.success =>
        dark ? const Color(0xFF7FD3A0) : const Color(0xFF15803D),
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: dark ? 0.12 : 0.07),
          scheme.surfaceContainerLowest,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconBadge(icon: icon, color: accent, size: 36),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Text(title, style: theme.textTheme.titleSmall),
                ),
                if (body case final body?) ...[
                  const SizedBox(height: 4),
                  DefaultTextStyle.merge(
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                    child: body,
                  ),
                ],
                if (action case final action?) ...[
                  const SizedBox(height: 12),
                  action,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// An icon on a soft tinted square, used beside titles and in notices.
class IconBadge extends StatelessWidget {
  const IconBadge({super.key, required this.icon, this.color, this.size = 40});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Theme.of(context).colorScheme.primary;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: Icon(icon, color: color, size: size * 0.55),
      ),
    );
  }
}

/// What a list shows while it is empty: an icon, a line, and a hint.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
  });

  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Column(
        children: [
          IconBadge(icon: icon, size: 64),
          const SizedBox(height: 16),
          Text(
            title,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          if (message case final message?) ...[
            const SizedBox(height: 6),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

/// A small uppercase label above a group of settings or a list.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(
          text.toUpperCase(),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}

/// A circle with someone's picture, or their initials tinted from their name
/// so each contact keeps the same colour.
///
/// The picture is shown only when it passes [AvatarData.parse] (a JPEG or PNG
/// data URI of at most [AvatarData.maxSharedLength] characters and
/// [AvatarData.maxSide] pixels a side); otherwise the initials are.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({
    super.key,
    required this.name,
    this.radius = 20,
    this.avatar,
  });

  final String name;
  final double radius;

  /// Optional picture as a `data:image/jpeg` or `data:image/png` base64 URI.
  final String? avatar;

  static const _hues = [262.0, 210.0, 170.0, 25.0, 330.0, 140.0, 45.0, 290.0];

  /// Checked, decoded pictures by data URI, most recently used last, so a
  /// rebuild reuses the same bytes (and the image cache keeps the decoded
  /// image) instead of decoding the base64 again. Rejected URIs are kept too
  /// (as null) so they are not checked again on every build.
  static final _pictures = <String, MemoryImage?>{};
  static const _cacheSize = 64;

  static MemoryImage? _picture(String uri) {
    if (_pictures.containsKey(uri)) {
      final cached = _pictures.remove(uri);
      return _pictures[uri] = cached;
    }
    final data = AvatarData.parse(uri);
    final picture = data == null ? null : MemoryImage(data.bytes);
    _pictures[uri] = picture;
    if (_pictures.length > _cacheSize) _pictures.remove(_pictures.keys.first);
    return picture;
  }

  /// How many pictures are cached (for tests).
  @visibleForTesting
  static int get cachedPictures => _pictures.length;

  @visibleForTesting
  static void clearCache() => _pictures.clear();

  @override
  Widget build(BuildContext context) {
    final uri = avatar;
    final picture = uri == null || uri.isEmpty ? null : _picture(uri);
    if (picture != null) {
      final pixels = (radius * 2 * MediaQuery.devicePixelRatioOf(context))
          .ceil();
      return ExcludeSemantics(
        child: CircleAvatar(
          radius: radius,
          backgroundColor: Colors.transparent,
          backgroundImage: ResizeImage(
            picture,
            width: pixels,
            height: pixels,
            allowUpscaling: true,
          ),
          // A picture that fails to decode after all shows nothing rather
          // than throwing.
          onBackgroundImageError: (_, _) {},
        ),
      );
    }

    final dark = Theme.of(context).brightness == Brightness.dark;
    final hue = _hues[name.codeUnits.fold(0, (a, b) => a + b) % _hues.length];
    final background = HSLColor.fromAHSL(
      1,
      hue,
      0.45,
      dark ? 0.28 : 0.90,
    ).toColor();
    final foreground = HSLColor.fromAHSL(
      1,
      hue,
      0.45,
      dark ? 0.85 : 0.30,
    ).toColor();
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: radius,
        backgroundColor: background,
        foregroundColor: foreground,
        child: Text(
          initials(name),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: radius * 0.72,
          ),
        ),
      ),
    );
  }

  /// Titles left out of initials ("Dr Meera Rao" is MR, not DR).
  static const _titles = {
    'dr',
    'mr',
    'mrs',
    'ms',
    'mx',
    'miss',
    'prof',
    'sir',
    'dame',
    'rev',
  };

  static String initials(String name) {
    var parts = name.trim().split(RegExp(r'\s+'));
    final named = parts
        .where((p) => !_titles.contains(p.toLowerCase().replaceAll('.', '')))
        .toList();
    if (named.isNotEmpty) parts = named;
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return '${parts.first.characters.first}${parts.last.characters.first}'
        .toUpperCase();
  }
}

/// A large [InitialsAvatar] with a camera button on its corner to choose a
/// picture. The button sits inside the avatar's square (so all of it can be
/// tapped), at its end corner (left in right-to-left languages), and is
/// labelled for screen readers.
class EditableAvatar extends StatelessWidget {
  const EditableAvatar({
    super.key,
    required this.name,
    required this.onPick,
    this.avatar,
    this.radius = 44,
  });

  final String name;
  final String? avatar;
  final double radius;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context).avatarChangePhoto;
    return SizedBox.square(
      dimension: radius * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          InitialsAvatar(name: name, avatar: avatar, radius: radius),
          PositionedDirectional(
            end: 0,
            bottom: 0,
            child: Semantics(
              button: true,
              label: label,
              onTap: onPick,
              excludeSemantics: true,
              child: Tooltip(
                message: label,
                excludeFromSemantics: true,
                child: Material(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onPick,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.photo_camera, size: 20),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lets the user choose an image file and makes it a profile picture (see
/// [makeAvatarDataUri]). Returns the picture's data URI, or null when no file
/// was chosen or it could not be used, in which case a snackbar says why.
Future<String?> chooseAvatarPicture(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context);
  try {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['jpg', 'jpeg', 'png', 'webp'],
          mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > maxAvatarInputBytes) {
      throw const AvatarException(AvatarError.inputTooLarge);
    }
    return await makeAvatarDataUri(await file.readAsBytes());
  } on AvatarException catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(switch (e.error) {
          AvatarError.inputTooLarge => l10n.avatarInputTooLarge,
          AvatarError.unreadable => l10n.avatarUnreadable,
          AvatarError.tooLarge => l10n.avatarTooLarge,
        }),
      ),
    );
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.avatarFailed)));
  }
  return null;
}
