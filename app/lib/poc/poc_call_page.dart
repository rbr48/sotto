import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/config.dart';
import 'poc_call_controller.dart';

/// Phase 1 test screen: join a room by code and video-call whoever else joins it.
class PocCallPage extends StatefulWidget {
  const PocCallPage({
    super.key,
    this.controller,
    this.initialRoom,
    this.autoJoin = false,
  });

  /// Injected in tests; created internally otherwise.
  final PocCallController? controller;

  /// Pre-filled room code, e.g. from a `?room=` link in the web build.
  final String? initialRoom;

  /// Join immediately on open (web links with `&join=1`).
  final bool autoJoin;

  @override
  State<PocCallPage> createState() => _PocCallPageState();
}

class _PocCallPageState extends State<PocCallPage> {
  late final PocCallController _controller =
      widget.controller ?? PocCallController();
  final _serverField = TextEditingController(text: SottoConfig.devRoomsUrl);
  late final _roomField = TextEditingController(
    text: widget.initialRoom ?? 'sotto-test',
  );
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    if (widget.autoJoin) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _join();
      });
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    _serverField.dispose();
    _roomField.dispose();
    super.dispose();
  }

  void _join() {
    if (!_formKey.currentState!.validate()) return;
    _controller.join(
      server: Uri.parse(_serverField.text.trim()),
      room: _roomField.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => Title(
        // Shows the call status in the browser tab.
        title: 'Sotto · ${_statusLabel(_controller.status)}',
        color: Theme.of(context).colorScheme.primary,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Sotto · test call'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(child: Text(_statusLabel(_controller.status))),
              ),
            ],
          ),
          body: SafeArea(
            child: _controller.inRoom
                ? _buildCall(context)
                : _buildJoinForm(context),
          ),
        ),
      ),
    );
  }

  Widget _buildJoinForm(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Join the same room code on two devices to start a video call.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                TextFormField(
                  key: const Key('server'),
                  controller: _serverField,
                  decoration: const InputDecoration(labelText: 'Relay server'),
                  validator: _validateServer,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('room'),
                  controller: _roomField,
                  decoration: const InputDecoration(labelText: 'Room code'),
                  validator: _validateRoom,
                  onFieldSubmitted: (_) => _join(),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const Key('join'),
                  onPressed: _join,
                  icon: const Icon(Icons.videocam),
                  label: const Text('Join'),
                ),
                if (_controller.error case final error?) ...[
                  const SizedBox(height: 16),
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCall(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black,
                  child: _controller.status == PocCallStatus.connected
                      ? RTCVideoView(
                          _controller.remoteRenderer,
                          objectFit: RTCVideoViewObjectFit
                              .RTCVideoViewObjectFitContain,
                        )
                      : Center(
                          child: Text(
                            _statusLabel(_controller.status),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 18,
                            ),
                          ),
                        ),
                ),
              ),
              if (_controller.safetyNumber case final number?)
                Positioned(
                  left: 12,
                  right: 12,
                  top: 12,
                  child: _SafetyNumberBanner(number: number),
                ),
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
                      _controller.localRenderer,
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
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Wrap(
            spacing: 16,
            alignment: WrapAlignment.center,
            children: [
              IconButton.filledTonal(
                tooltip: _controller.micEnabled ? 'Mute' : 'Unmute',
                onPressed: _controller.toggleMic,
                icon: Icon(_controller.micEnabled ? Icons.mic : Icons.mic_off),
              ),
              IconButton.filledTonal(
                tooltip: _controller.cameraEnabled
                    ? 'Turn camera off'
                    : 'Turn camera on',
                onPressed: _controller.toggleCamera,
                icon: Icon(
                  _controller.cameraEnabled
                      ? Icons.videocam
                      : Icons.videocam_off,
                ),
              ),
              if (Theme.of(context).platform == TargetPlatform.android)
                IconButton.filledTonal(
                  tooltip: 'Switch camera',
                  onPressed: _controller.switchCamera,
                  icon: const Icon(Icons.cameraswitch),
                ),
              IconButton.filled(
                tooltip: 'Hang up',
                style: IconButton.styleFrom(backgroundColor: scheme.error),
                onPressed: _controller.hangUp,
                icon: Icon(Icons.call_end, color: scheme.onError),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Shows that signaling is end-to-end encrypted, with the safety number both
/// people can compare (out loud, or by looking) to rule out interception.
class _SafetyNumberBanner extends StatelessWidget {
  const _SafetyNumberBanner({required this.number});

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

String _statusLabel(PocCallStatus status) => switch (status) {
  PocCallStatus.idle => 'Not connected',
  PocCallStatus.joining => 'Joining…',
  PocCallStatus.waitingForPeer => 'Waiting for the other person…',
  PocCallStatus.connecting => 'Connecting…',
  PocCallStatus.connected => 'Connected',
  PocCallStatus.failed => 'Failed',
};

String? _validateServer(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null ||
      !(uri.scheme == 'ws' || uri.scheme == 'wss') ||
      uri.host.isEmpty) {
    return 'Enter a ws:// or wss:// address';
  }
  return null;
}

String? _validateRoom(String? value) {
  final room = value?.trim() ?? '';
  if (!RegExp(r'^[A-Za-z0-9_-]{4,64}$').hasMatch(room)) {
    return '4–64 letters, numbers, - or _';
  }
  return null;
}
