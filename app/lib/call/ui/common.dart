import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../relay/relay_client.dart';
import '../call_controller.dart';
import '../call_manager.dart';
import '../media_engine.dart';

/// The connecting/connected call: remote video, own preview, safety number,
/// route and controls. Shared by the professional's and the guest's screens.
class InCallView extends StatelessWidget {
  const InCallView({super.key, required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final call = controller.call;

    return Column(
      children: [
        Expanded(
          child: Stack(
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
                    if (controller.safetyNumber case final number?)
                      SafetyNumberBadge(number: number),
                    if (controller.route case final route?) ...[
                      const SizedBox(height: 8),
                      Pill(
                        text: switch (route) {
                          MediaRoute.direct => 'Direct connection',
                          MediaRoute.relayed =>
                            'Relayed through Sotto · IP addresses hidden',
                        },
                      ),
                    ],
                  ],
                ),
              ),
              if (call.video)
                Positioned(
                  right: 16,
                  bottom: 16,
                  width: 160,
                  height: 120,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: ColoredBox(
                      color: Colors.black54,
                      child: RTCVideoView(
                        controller.localRenderer,
                        mirror: true,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        ControlBar(
          children: [
            IconButton.filledTonal(
              tooltip: controller.micEnabled ? 'Mute' : 'Unmute',
              onPressed: controller.toggleMic,
              icon: Icon(controller.micEnabled ? Icons.mic : Icons.mic_off),
            ),
            if (call.video)
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
                Theme.of(context).platform == TargetPlatform.android)
              IconButton.filledTonal(
                tooltip: 'Switch camera',
                onPressed: controller.switchCamera,
                icon: const Icon(Icons.cameraswitch),
              ),
            HangUpButton(controller: controller, tooltip: 'Hang up'),
          ],
        ),
      ],
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
  const Pill({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
    borderRadius: BorderRadius.circular(24),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
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
