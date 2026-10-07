import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../call_controller.dart';
import '../call_manager.dart';
import 'common.dart';

/// The full-screen call: outgoing, incoming, or connected. Shown on top of
/// everything else (also while the app is locked, like a phone).
class CallScreen extends StatelessWidget {
  const CallScreen({super.key, required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final call = controller.call;
    return switch (call.phase) {
      CallPhase.calling || CallPhase.ringing => _Outgoing(controller),
      CallPhase.incoming => _Incoming(controller),
      _ => Stack(
        children: [
          Positioned.fill(child: InCallView(controller: controller)),
          if (controller.guestHost?.waiting.length case final n? when n > 0)
            Positioned(
              left: 12,
              bottom: 96,
              child: Pill(
                text: n == 1 ? '1 guest waiting' : '$n guests waiting',
              ),
            ),
        ],
      ),
    };
  }
}

class _Outgoing extends StatelessWidget {
  const _Outgoing(this.controller);

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final call = controller.call;
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              if (call.video)
                Positioned.fill(
                  child: RTCVideoView(
                    controller.localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Pill(text: controller.peerName),
                    const SizedBox(height: 12),
                    Pill(
                      text: call.phase == CallPhase.ringing
                          ? 'Ringing…'
                          : 'Calling… (waiting for their device)',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ControlBar(
          children: [HangUpButton(controller: controller, tooltip: 'Cancel')],
        ),
      ],
    );
  }
}

class _Incoming extends StatelessWidget {
  const _Incoming(this.controller);

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final call = controller.call;
    final contact = controller.peerContact;
    return Centered(
      child: Column(
        children: [
          Icon(
            call.video ? Icons.videocam : Icons.call,
            size: 64,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            call.video ? 'Incoming video call' : 'Incoming voice call',
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            controller.peerName,
            key: const Key('caller-name'),
            style: theme.textTheme.titleLarge,
          ),
          if (contact != null && !contact.verified)
            Text(
              'Safety number not yet compared',
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 16),
          if (controller.safetyNumber case final number?)
            SafetyNumberBadge(number: number),
          const SizedBox(height: 32),
          Wrap(
            spacing: 24,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                ),
                onPressed: controller.decline,
                icon: const Icon(Icons.call_end),
                label: const Text('Decline'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                ),
                onPressed: controller.accept,
                icon: const Icon(Icons.call),
                label: const Text('Accept'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
