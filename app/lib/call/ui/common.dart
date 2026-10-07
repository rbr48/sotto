import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../relay/relay_client.dart';
import '../call_controller.dart';
import '../call_manager.dart';
import '../devices.dart';
import '../media_engine.dart';

/// The connecting/connected call: remote video, own preview, safety number,
/// timer, quality, route and controls. Shared by the professional's app,
/// browser quick calls and the guest's page.
class InCallView extends StatelessWidget {
  const InCallView({super.key, required this.controller, this.title});

  final CallController controller;

  /// Who the call is with (e.g. the professional's name on a guest page).
  final String? title;

  @override
  Widget build(BuildContext context) {
    final call = controller.call;
    final name = title ?? controller.peerName;

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black,
                    child: call.phase == CallPhase.connected && call.video
                        ? RTCVideoView(
                            controller.remoteRenderer,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitContain,
                          )
                        : Center(
                            child: Text(
                              call.phase == CallPhase.connected
                                  ? 'Voice call'
                                  : 'Connecting…',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 18,
                              ),
                            ),
                          ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  top: 12,
                  child: Column(
                    children: [
                      Pill(
                        text: call.phase == CallPhase.connected
                            ? name
                            : '$name · connecting…',
                        trailing: controller.connectedAt == null
                            ? null
                            : CallTimer(since: controller.connectedAt!),
                      ),
                      const SizedBox(height: 8),
                      if (controller.safetyNumber case final number?)
                        SafetyNumberBadge(number: number),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        children: [
                          if (controller.autoAnswered)
                            const _SmallPill(
                              icon: Icons.phone_callback,
                              text: 'Auto-answered',
                            ),
                          if (controller.route case final route?)
                            _SmallPill(
                              icon: route == MediaRoute.relayed
                                  ? Icons.shield_outlined
                                  : Icons.swap_horiz,
                              text: switch (route) {
                                MediaRoute.direct => 'Direct connection',
                                MediaRoute.relayed =>
                                  'Relayed through Sotto · IP addresses hidden',
                              },
                            ),
                          if (controller.quality case final quality?)
                            QualityPill(quality: quality),
                        ],
                      ),
                    ],
                  ),
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
        ControlBar(
          children: [
            IconButton.filledTonal(
              tooltip: controller.micEnabled ? 'Mute' : 'Unmute',
              onPressed: controller.toggleMic,
              icon: Icon(controller.micEnabled ? Icons.mic : Icons.mic_off),
            ),
            if (call.video && controller.sendingVideo)
              IconButton.filledTonal(
                tooltip: controller.cameraEnabled
                    ? 'Turn camera off'
                    : 'Turn camera on',
                onPressed: controller.toggleCamera,
                icon: Icon(
                  controller.cameraEnabled
                      ? Icons.videocam
                      : Icons.videocam_off,
                ),
              ),
            if (call.video &&
                controller.sendingVideo &&
                Theme.of(context).platform == TargetPlatform.android)
              IconButton.filledTonal(
                tooltip: 'Switch camera',
                onPressed: controller.switchCamera,
                icon: const Icon(Icons.cameraswitch),
              ),
            if (controller.devices != null)
              IconButton.filledTonal(
                tooltip: 'Audio and video devices',
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (_) => DevicePicker(controller: controller),
                ),
                icon: const Icon(Icons.tune),
              ),
            HangUpButton(controller: controller, tooltip: 'Hang up'),
          ],
        ),
      ],
    );
  }
}

/// Mm:ss since the call connected.
class CallTimer extends StatefulWidget {
  const CallTimer({super.key, required this.since});

  final DateTime since;

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
    style: Theme.of(context).textTheme.titleMedium
        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
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

class QualityPill extends StatelessWidget {
  const QualityPill({super.key, required this.quality});

  final CallQuality quality;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (quality) {
      CallQuality.good => ('Good connection', Colors.green),
      CallQuality.fair => ('Fair connection', Colors.orange),
      CallQuality.poor => ('Poor connection', Colors.red),
    };
    return _SmallPill(
      icon: Icons.signal_cellular_alt,
      iconColor: color,
      text: text,
    );
  }
}

class _SmallPill extends StatelessWidget {
  const _SmallPill({required this.icon, required this.text, this.iconColor});

  final IconData icon;
  final String text;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 6),
            Text(text, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
      ),
    ),
  );
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
  Offset? _position;

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

  @override
  Widget build(BuildContext context) {
    final position = _clamp(
      _position ??
          Offset(
            widget.area.width - _size.width - _margin,
            widget.area.height - _size.height - _margin,
          ),
    );
    return Positioned(
      left: position.dx,
      top: position.dy,
      width: _size.width,
      height: _size.height,
      child: Semantics(
        label: 'Your video (drag to move)',
        child: GestureDetector(
          key: const Key('self-preview'),
          onPanUpdate: (details) =>
              setState(() => _position = _clamp(position + details.delta)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(color: Colors.black54, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// Camera, microphone and speaker choices (also during a call).
class DevicePicker extends StatelessWidget {
  const DevicePicker({super.key, required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.devices;
    if (devices == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: devices,
      builder: (context, _) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
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
          ],
        ),
      ),
    );
  }
}

class HangUpButton extends StatelessWidget {
  const HangUpButton({
    super.key,
    required this.controller,
    required this.tooltip,
  });

  final CallController controller;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton.filled(
      tooltip: tooltip,
      style: IconButton.styleFrom(backgroundColor: scheme.error),
      onPressed: controller.hangUp,
      icon: Icon(Icons.call_end, color: scheme.onError),
    );
  }
}

/// Sotto's logo: a speech bubble with a quiet sound wave (drawn by
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

class ControlBar extends StatelessWidget {
  const ControlBar({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Wrap(
      spacing: 16,
      alignment: WrapAlignment.center,
      children: children,
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
    final (label, color) = switch (status) {
      RelayStatus.online => ('Online', Colors.green),
      RelayStatus.connecting => ('Connecting…', Colors.orange),
      RelayStatus.offline => ('Offline', Colors.red),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Chip(
        avatar: Icon(Icons.circle, size: 12, color: color),
        label: Text(label),
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
    CallPhase.connected => 'Connected',
    CallPhase.ended => 'Call ended (${shortEndReason(call.endReason)})',
  };
}
