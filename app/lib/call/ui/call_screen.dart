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
    return ColoredBox(
      color: callStage,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                if (call.video)
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.35,
                      child: RTCVideoView(
                        controller.localRenderer,
                        mirror: true,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: CallStage(
                    name: controller.peerName,
                    status: call.phase == CallPhase.ringing
                        ? 'Ringing…'
                        : 'Calling…',
                    note: call.phase == CallPhase.ringing
                        ? null
                        : 'Waiting for their device',
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
              child: RoundCallButton(
                tooltip: 'Cancel',
                label: 'End',
                icon: Icons.call_end,
                danger: true,
                onPressed: controller.hangUp,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Incoming extends StatelessWidget {
  const _Incoming(this.controller);

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final call = controller.call;
    final contact = controller.peerContact;
    return ColoredBox(
      color: callStage,
      child: Column(
        children: [
          Expanded(
            child: CallStage(
              name: controller.peerName,
              note: contact != null && !contact.verified
                  ? 'Safety number not yet compared'
                  : null,
              status: call.video
                  ? 'Incoming video call'
                  : 'Incoming voice call',
              extra: controller.safetyNumber == null
                  ? null
                  : TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                      ),
                      onPressed: () => showSafetyNumber(
                        context,
                        number: controller.safetyNumber!,
                        peerName: splitPeerName(controller.peerName).$1,
                        verified: contact?.verified ?? false,
                      ),
                      icon: const Icon(Icons.lock, size: 16),
                      label: const Text('End-to-end encrypted'),
                    ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 72,
                children: [
                  RoundCallButton(
                    tooltip: 'Decline',
                    label: 'Decline',
                    icon: Icons.call_end,
                    danger: true,
                    onPressed: controller.decline,
                  ),
                  RoundCallButton(
                    tooltip: 'Accept',
                    label: 'Accept',
                    icon: call.video ? Icons.videocam : Icons.call,
                    color: const Color(0xFF2FA84F),
                    onPressed: controller.accept,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
