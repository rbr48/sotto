import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../relay/relay_client.dart';
import '../call_controller.dart';
import '../call_manager.dart';
import '../devices.dart';
import '../media_engine.dart';

/// The connecting/connected call: remote video (or, for voice, the other
/// person's initials), own preview, timer and controls. Shared by the
/// professional's app, browser quick calls and the guest's page.
///
/// Status stays small and out of the way: a lock (tap it for the safety
/// number), the connection quality, and whether the call is relayed.
class InCallView extends StatelessWidget {
  const InCallView({super.key, required this.controller, this.title});

  final CallController controller;

  /// Who the call is with (e.g. the professional's name on a guest page).
  final String? title;

  @override
  Widget build(BuildContext context) {
    final call = controller.call;
    final name = title ?? controller.peerName;
    final connected = call.phase == CallPhase.connected;
    final showVideo = connected && call.video;
    final status = call.reconnecting
        ? 'Reconnecting…'
        : connected
        ? null
        : 'Connecting…';

    return ColoredBox(
      color: callStage,
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                children: [
                  Positioned.fill(
                    child: showVideo
                        ? RTCVideoView(
                            controller.remoteRenderer,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitContain,
                          )
                        : CallStage(
                            name: name,
                            timerSince: controller.connectedAt,
                            status: status,
                          ),
                  ),
                  if (showVideo)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: _VideoHeader(
                        name: name,
                        connectedAt: controller.connectedAt,
                        status: status,
                      ),
                    ),
                  Positioned(
                    left: 12,
                    right: 12,
                    top: showVideo ? 72 : 12,
                    child: _StatusRow(controller: controller, peerName: name),
                  ),
                  if (call.video && controller.sendingVideo)
                    DraggablePreview(
                      area: constraints.biggest,
                      child: RTCVideoView(
                        controller.localRenderer,
                        mirror: true,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    ),
                ],
              ),
            ),
          ),
          _CallControls(controller: controller),
        ],
      ),
    );
  }
}

/// The dark background of every call screen.
const callStage = Color(0xFF101014);

/// Splits off the "not in your contacts" mark: the name, and a note to
/// show under it (or `null`).
(String, String?) splitPeerName(String name) {
  const mark = CallController.notInContacts;
  return name.endsWith(mark)
      ? (name.substring(0, name.length - mark.length), 'Not in your contacts')
      : (name, null);
}

/// The calm middle of every call screen: initials, name, a note, and the
/// status (ringing, a timer, …).
class CallStage extends StatelessWidget {
  const CallStage({
    super.key,
    required this.name,
    this.note,
    this.status,
    this.timerSince,
    this.extra,
  });

  final String name;

  /// e.g. "Not in your contacts".
  final String? note;

  /// e.g. "Ringing…"; a timer instead if [timerSince] is set and this is
  /// `null`.
  final String? status;
  final DateTime? timerSince;

  /// Under the status (e.g. the "End-to-end encrypted" button).
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (shown, mark) = splitPeerName(name);
    final subtitle = note ?? mark;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 72),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 56,
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              child: shown == 'Unknown caller'
                  ? const Icon(Icons.person, size: 56)
                  : Text(
                      initialsOf(shown),
                      style: const TextStyle(
                        fontSize: 38,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
            const SizedBox(height: 20),
            Text(
              shown,
              key: const Key('caller-name'),
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white54,
                ),
              ),
            ],
            const SizedBox(height: 10),
            if (status != null || timerSince == null)
              Text(
                status ?? 'Connecting…',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white70,
                ),
              )
            else
              CallTimer(since: timerSince!, color: Colors.white70),
            if (extra != null) ...[const SizedBox(height: 16), extra!],
          ],
        ),
      ),
    );
  }
}

/// Video calls: the name and timer over the top of the picture.
class _VideoHeader extends StatelessWidget {
  const _VideoHeader({
    required this.name,
    required this.connectedAt,
    required this.status,
  });

  final String name;
  final DateTime? connectedAt;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
        child: Row(
          children: [
            Expanded(
              child: Text(
                splitPeerName(name).$1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            DefaultTextStyle.merge(
              style: const TextStyle(color: Colors.white),
              child: status != null
                  ? Text(status!, style: const TextStyle(color: Colors.white))
                  : connectedAt != null
                  ? CallTimer(since: connectedAt!, color: Colors.white)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small chips: encrypted (tap for the safety number), auto-answered,
/// relayed, quality, reconnecting.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.controller, required this.peerName});

  final CallController controller;
  final String peerName;

  @override
  Widget build(BuildContext context) {
    final call = controller.call;
    final route = controller.route;
    final quality = controller.quality;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        if (controller.safetyNumber case final number?)
          _Chip(
            icon: Icons.lock,
            text: 'Encrypted',
            tooltip: 'End-to-end encrypted. Show the safety number',
            onTap: () => showSafetyNumber(
              context,
              number: number,
              peerName: splitPeerName(peerName).$1,
              verified: controller.peerContact?.verified ?? false,
            ),
          ),
        if (controller.autoAnswered)
          const _Chip(icon: Icons.phone_callback, text: 'Auto-answered'),
        if (call.reconnecting)
          const ReconnectingPill()
        else ...[
          if (route == MediaRoute.relayed)
            const _Chip(
              icon: Icons.shield_outlined,
              text: 'Relayed',
              tooltip: 'Relayed through Sotto: IP addresses are hidden',
            ),
          if (quality != null) QualityPill(quality: quality),
        ],
      ],
    );
  }
}

/// The safety number, on request: both people see the same numbers if no
/// one is in between.
Future<void> showSafetyNumber(
  BuildContext context, {
  required String number,
  required String peerName,
  required bool verified,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Text('End-to-end encrypted', style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              verified
                  ? 'You compared this safety number with $peerName before.'
                  : 'Only you and $peerName can hear and see this call. To be '
                        'sure no one is in between, compare these numbers with '
                        'theirs, in person or over another channel. They must '
                        'be the same.',
            ),
            const SizedBox(height: 16),
            SafetyNumberBadge(number: number),
          ],
        ),
      ),
    );
  },
);

/// A small status chip over the call.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.text,
    this.iconColor,
    this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String text;
  final Color? iconColor;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Widget chip = Material(
      color: const Color(0x66000000),
      shape: const StadiumBorder(side: BorderSide(color: Color(0x33FFFFFF))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: iconColor ?? Colors.white70),
              const SizedBox(width: 5),
              Text(
                text,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    );
    if (onTap != null) {
      chip = Semantics(
        button: true,
        label: tooltip ?? text,
        excludeSemantics: true,
        child: chip,
      );
    }
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// Round buttons with a label under each: mute, camera, switch camera,
/// devices, hang up.
class _CallControls extends StatelessWidget {
  const _CallControls({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final call = controller.call;
    final video = call.video && controller.sendingVideo;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 18,
          runSpacing: 12,
          children: [
            RoundCallButton(
              tooltip: controller.micEnabled ? 'Mute' : 'Unmute',
              label: controller.micEnabled ? 'Mute' : 'Unmute',
              icon: controller.micEnabled ? Icons.mic : Icons.mic_off,
              active: !controller.micEnabled,
              onPressed: controller.toggleMic,
            ),
            if (video)
              RoundCallButton(
                tooltip: controller.cameraEnabled
                    ? 'Turn camera off'
                    : 'Turn camera on',
                label: 'Camera',
                icon: controller.cameraEnabled
                    ? Icons.videocam
                    : Icons.videocam_off,
                active: !controller.cameraEnabled,
                onPressed: controller.toggleCamera,
              ),
            if (video && Theme.of(context).platform == TargetPlatform.android)
              RoundCallButton(
                tooltip: 'Switch camera',
                label: 'Flip',
                icon: Icons.cameraswitch,
                onPressed: controller.switchCamera,
              ),
            if (controller.devices != null)
              RoundCallButton(
                tooltip: 'Audio and video devices',
                label: 'Devices',
                icon: Icons.tune,
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (_) => DevicePicker(controller: controller),
                ),
              ),
            RoundCallButton(
              tooltip: 'Hang up',
              label: 'End',
              icon: Icons.call_end,
              danger: true,
              onPressed: controller.hangUp,
            ),
          ],
        ),
      ),
    );
  }
}

class RoundCallButton extends StatelessWidget {
  const RoundCallButton({
    super.key,
    required this.tooltip,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.danger = false,
    this.color,
  });

  final String tooltip;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  /// Switched on (e.g. muted): shown light.
  final bool active;
  final bool danger;

  /// A colour of its own (e.g. green for Accept).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final background = color != null
        ? color!
        : danger
        ? const Color(0xFFE5484D)
        : active
        ? Colors.white
        : const Color(0xFF2A2A31);
    final foreground = active && !danger ? Colors.black : Colors.white;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          iconSize: 26,
          style: IconButton.styleFrom(
            backgroundColor: background,
            foregroundColor: foreground,
            fixedSize: const Size.square(64),
          ),
          icon: Icon(icon),
        ),
        const SizedBox(height: 6),
        ExcludeSemantics(
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// Up to two initials for an avatar ("Dr Meera Rao (Lotus)" → "DR").
String initialsOf(String name) {
  final words = name
      .replaceAll(RegExp(r'\(.*?\)'), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '?';
  final first = words.first.characters.first;
  final last = words.length > 1 ? words.last.characters.first : '';
  return '$first$last'.toUpperCase();
}

/// Mm:ss since the call connected.
class CallTimer extends StatefulWidget {
  const CallTimer({super.key, required this.since, this.color});

  final DateTime since;

  /// Over the dark call stage, a light colour.
  final Color? color;

  @override
  State<CallTimer> createState() => _CallTimerState();
}

class _CallTimerState extends State<CallTimer> {
  late final Timer _timer = Timer.periodic(
    const Duration(seconds: 1),
    (_) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    _timer;
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    formatDuration(DateTime.now().difference(widget.since)),
    key: const Key('call-timer'),
    style: Theme.of(context).textTheme.titleMedium?.copyWith(
      color: widget.color,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}

/// "4:05" or "1:02:03".
String formatDuration(Duration duration) {
  final d = duration.isNegative ? Duration.zero : duration;
  String two(int n) => n.toString().padLeft(2, '0');
  final minutes = d.inMinutes.remainder(60);
  final seconds = two(d.inSeconds.remainder(60));
  return d.inHours > 0
      ? '${d.inHours}:${two(minutes)}:$seconds'
      : '$minutes:$seconds';
}

/// The network changed or dropped: the call is looking for a new path and
/// goes on by itself once it finds one.
class ReconnectingPill extends StatelessWidget {
  const ReconnectingPill({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: const _Chip(
      icon: Icons.sync_problem,
      iconColor: Colors.orange,
      text: 'Reconnecting… the call continues when the network is back',
    ),
  );
}

class QualityPill extends StatelessWidget {
  const QualityPill({super.key, required this.quality});

  final CallQuality quality;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (quality) {
      CallQuality.good => ('Good connection', Colors.greenAccent),
      CallQuality.fair => ('Fair connection', Colors.orangeAccent),
      CallQuality.poor => ('Poor connection', Colors.redAccent),
    };
    return _Chip(icon: Icons.signal_cellular_alt, iconColor: color, text: text);
  }
}

/// The user's own video, which can be dragged anywhere in the call area.
class DraggablePreview extends StatefulWidget {
  const DraggablePreview({super.key, required this.area, required this.child});

  final Size area;
  final Widget child;

  @override
  State<DraggablePreview> createState() => _DraggablePreviewState();
}

class _DraggablePreviewState extends State<DraggablePreview> {
  static const _size = Size(160, 120);
  static const _margin = 16.0;

  /// Where the user put it; `null` = the bottom right corner.
  Offset? _position;
  bool _dragging = false;

  Offset _clamp(Offset p) => Offset(
    p.dx.clamp(
      _margin,
      max(_margin, widget.area.width - _size.width - _margin),
    ),
    p.dy.clamp(
      _margin,
      max(_margin, widget.area.height - _size.height - _margin),
    ),
  );

  /// The corner nearest to [p]: the window snaps there when let go.
  Offset _nearestCorner(Offset p) {
    final right = widget.area.width - _size.width - _margin;
    final bottom = widget.area.height - _size.height - _margin;
    final centre = p + Offset(_size.width / 2, _size.height / 2);
    return _clamp(
      Offset(
        centre.dx < widget.area.width / 2 ? _margin : right,
        centre.dy < widget.area.height / 2 ? _margin : bottom,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final position = _clamp(
      _position ??
          Offset(
            widget.area.width - _size.width - _margin,
            widget.area.height - _size.height - _margin,
          ),
    );
    return AnimatedPositioned(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: position.dx,
      top: position.dy,
      width: _size.width,
      height: _size.height,
      child: Semantics(
        label: 'Your video (drag to move)',
        child: GestureDetector(
          key: const Key('self-preview'),
          // The whole window takes the drag, not only the video in it.
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => setState(() => _dragging = true),
          // From where it is now, not where it was when last drawn: a quick
          // flick ends before the next frame.
          onPanUpdate: (details) => setState(
            () => _position = _clamp((_position ?? position) + details.delta),
          ),
          onPanEnd: (_) => setState(() {
            _dragging = false;
            _position = _nearestCorner(_position ?? position);
          }),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0x55FFFFFF)),
              boxShadow: const [
                BoxShadow(color: Color(0x66000000), blurRadius: 12),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: ColoredBox(color: Colors.black54, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Camera, microphone and speaker choices (also during a call).
class DevicePicker extends StatelessWidget {
  const DevicePicker({
    super.key,
    required this.controller,
    this.embedded = false,
  });

  final CallController controller;

  /// Part of a page that scrolls (Settings): a plain column, so scrolling
  /// over the choices scrolls the page. Otherwise (the in-call sheet) it
  /// scrolls by itself.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final devices = controller.devices;
    if (devices == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: devices,
      builder: (context, _) {
        final choices = [
          for (final kind in DeviceKind.values) ...[
            Text(switch (kind) {
              DeviceKind.camera => 'Camera',
              DeviceKind.microphone => 'Microphone',
              DeviceKind.speaker => 'Speaker',
            }, style: Theme.of(context).textTheme.titleSmall),
            RadioGroup<String?>(
              groupValue: devices.effective.idFor(kind),
              onChanged: (id) => controller.useDevice(kind, id),
              child: Column(
                children: [
                  const RadioListTile<String?>(
                    value: null,
                    title: Text('System default'),
                  ),
                  for (final device in devices.available(kind))
                    RadioListTile<String?>(
                      value: device.id,
                      title: Text(device.label),
                    ),
                ],
              ),
            ),
          ],
        ];
        if (embedded) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: choices,
          );
        }
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: choices,
          ),
        );
      },
    );
  }
}

/// Sotto's logo mark: a speech bubble with a quiet sound wave (drawn by
/// tools/icons/generate.py). Decorative: screen readers skip it.
class SottoLogo extends StatelessWidget {
  const SottoLogo({super.key, this.size = 72});
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/brand/logo.png',
    width: size,
    height: size,
    excludeFromSemantics: true,
    filterQuality: FilterQuality.medium,
  );
}

/// The "sotto" wordmark (drawn by tools/icons/wordmark.py), for light or
/// dark themes. Screen readers read it as "Sotto".
class SottoWordmark extends StatelessWidget {
  const SottoWordmark({super.key, this.height = 48});
  final double height;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      label: 'Sotto',
      header: true,
      child: Image.asset(
        dark
            ? 'assets/brand/wordmark-dark.png'
            : 'assets/brand/wordmark-light.png',
        height: height,
        excludeFromSemantics: true,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

class Centered extends StatelessWidget {
  const Centered({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: child,
      ),
    ),
  );
}

class Pill extends StatelessWidget {
  const Pill({super.key, required this.text, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
    borderRadius: BorderRadius.circular(24),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing case final trailing?) ...[
            const SizedBox(width: 12),
            trailing,
          ],
        ],
      ),
    ),
  );
}

class RelayStatusChip extends StatelessWidget {
  const RelayStatusChip({super.key, required this.status});
  final RelayStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (status) {
      RelayStatus.online => ('Online', Colors.green),
      RelayStatus.connecting => ('Connecting…', Colors.orange),
      RelayStatus.offline => ('Offline', Colors.red),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows that the call is end-to-end encrypted, with the safety number both
/// people can compare to rule out interception.
class SafetyNumberBadge extends StatelessWidget {
  const SafetyNumberBadge({super.key, required this.number});
  final String number;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Material(
        color: scheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'End-to-end encrypted · safety number',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    SelectableText(
                      number,
                      key: const Key('safety-number'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String shortEndReason(CallEndReason? reason) => switch (reason) {
  CallEndReason.hungUp => 'you hung up',
  CallEndReason.remoteHungUp => 'they hung up',
  CallEndReason.declined => 'you declined',
  CallEndReason.remoteDeclined => 'declined',
  CallEndReason.busy => 'busy',
  CallEndReason.noAnswer => 'no answer',
  CallEndReason.cancelled => 'cancelled',
  CallEndReason.missed => 'missed',
  CallEndReason.failed || null => 'failed',
};

String describeEnd(CallState call) => switch (call.endReason) {
  CallEndReason.hungUp => 'You hung up.',
  CallEndReason.remoteHungUp => 'The other person hung up.',
  CallEndReason.declined => 'You declined the call.',
  CallEndReason.remoteDeclined => 'The other person declined the call.',
  CallEndReason.busy => 'The other person is on another call.',
  CallEndReason.noAnswer => 'No answer.',
  CallEndReason.cancelled => 'You cancelled the call.',
  CallEndReason.missed => 'Missed call.',
  CallEndReason.failed || null => 'The call failed. ${call.error ?? ''}'.trim(),
};

/// The window title for a call state, e.g. "Ready" or "Call ended (busy)".
/// (The end-to-end tests read these.)
String callTitleLabel(CallController controller) {
  final call = controller.call;
  return switch (call.phase) {
    CallPhase.idle => switch (controller.relayStatus) {
      RelayStatus.online => 'Ready',
      RelayStatus.connecting => 'Connecting to relay…',
      RelayStatus.offline => 'Offline',
    },
    CallPhase.calling => 'Calling…',
    CallPhase.ringing => 'Ringing…',
    CallPhase.incoming => 'Incoming call',
    CallPhase.connecting => 'Connecting…',
    CallPhase.connected when call.reconnecting => 'Reconnecting',
    CallPhase.connected => 'Connected',
    CallPhase.ended => 'Call ended (${shortEndReason(call.endReason)})',
  };
}
