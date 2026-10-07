import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../crypto/identity.dart';
import '../../relay/relay_client.dart';
import '../call_controller.dart';
import '../call_manager.dart';

/// The test call screen: share your call link, call someone else's, and
/// handle incoming calls.
class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.controller, this.autoCallLink});

  final CallController controller;

  /// A call link to dial as soon as the relay is reachable (web `?call=`).
  final String? autoCallLink;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  CallController get _controller => widget.controller;
  final _linkField = TextEditingController();
  String? _linkError;
  bool _autoCallPending = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoCallLink case final link?) {
      _linkField.text = link;
      _autoCallPending = true;
    }
    _controller.addListener(_maybeAutoCall);
  }

  @override
  void dispose() {
    _controller.removeListener(_maybeAutoCall);
    _linkField.dispose();
    super.dispose();
  }

  void _maybeAutoCall() {
    if (_autoCallPending && _controller.relayStatus == RelayStatus.online) {
      _autoCallPending = false;
      unawaited(_call(video: true));
    }
  }

  Future<void> _call({required bool video}) async {
    setState(() => _linkError = null);
    try {
      await _controller.callSomeone(_linkField.text, video: video);
    } on InvalidIdentityException catch (e) {
      setState(() => _linkError = _describeLinkError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final call = _controller.call;
        return Title(
          title: 'Sotto · ${_titleLabel(_controller, call)}',
          color: Theme.of(context).colorScheme.primary,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Sotto'),
              actions: [_RelayStatusChip(status: _controller.relayStatus)],
            ),
            body: SafeArea(child: _buildBody(context, call)),
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, CallState call) {
    if (_controller.startupError case final error?) {
      return _Centered(child: Text('Sotto could not start: $error'));
    }
    if (!_controller.ready) {
      return const _Centered(child: CircularProgressIndicator());
    }
    return switch (call.phase) {
      CallPhase.idle || CallPhase.ended => _buildHome(context, call),
      CallPhase.calling || CallPhase.ringing => _buildOutgoing(context, call),
      CallPhase.incoming => _buildIncoming(context, call),
      CallPhase.connecting ||
      CallPhase.connected => _buildInCall(context, call),
    };
  }

  Widget _buildHome(BuildContext context, CallState call) {
    final theme = Theme.of(context);
    return _Centered(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (call.phase == CallPhase.ended) ...[
            Card(
              color: theme.colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.call_end),
                title: Text(_describeEnd(call)),
                trailing: TextButton(
                  onPressed: _controller.dismiss,
                  child: const Text('OK'),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_controller.identityWarning case final warning?) ...[
            Text(warning, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 16),
          ],
          Text('Your call link', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Anyone with this link can call you. Calls are end-to-end encrypted.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  _controller.callLink ?? '',
                  maxLines: 2,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy link',
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(text: _controller.callLink ?? ''),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Call link copied')),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 32),
          Text('Call someone', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            key: const Key('call-link-field'),
            controller: _linkField,
            decoration: InputDecoration(
              labelText: 'Their call link',
              errorText: _linkError,
            ),
            onSubmitted: (_) => _call(video: true),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () => _call(video: true),
                icon: const Icon(Icons.videocam),
                label: const Text('Video call'),
              ),
              OutlinedButton.icon(
                onPressed: () => _call(video: false),
                icon: const Icon(Icons.call),
                label: const Text('Voice call'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOutgoing(BuildContext context, CallState call) {
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              if (call.video)
                Positioned.fill(
                  child: RTCVideoView(
                    _controller.localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              Center(
                child: _Pill(
                  text: call.phase == CallPhase.ringing
                      ? 'Ringing…'
                      : 'Calling… (waiting for their device)',
                ),
              ),
            ],
          ),
        ),
        _ControlBar(children: [_hangUpButton(context, tooltip: 'Cancel')]),
      ],
    );
  }

  Widget _buildIncoming(BuildContext context, CallState call) {
    final theme = Theme.of(context);
    return _Centered(
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
          const SizedBox(height: 16),
          if (_controller.safetyNumber case final number?)
            _SafetyNumber(number: number),
          const SizedBox(height: 32),
          Wrap(
            spacing: 24,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                ),
                onPressed: _controller.decline,
                icon: const Icon(Icons.call_end),
                label: const Text('Decline'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                ),
                onPressed: _controller.accept,
                icon: const Icon(Icons.call),
                label: const Text('Accept'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInCall(BuildContext context, CallState call) {
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
                          _controller.remoteRenderer,
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
              if (_controller.safetyNumber case final number?)
                Positioned(
                  left: 12,
                  right: 12,
                  top: 12,
                  child: _SafetyNumber(number: number),
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
        _ControlBar(
          children: [
            IconButton.filledTonal(
              tooltip: _controller.micEnabled ? 'Mute' : 'Unmute',
              onPressed: _controller.toggleMic,
              icon: Icon(_controller.micEnabled ? Icons.mic : Icons.mic_off),
            ),
            if (call.video)
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
            if (call.video &&
                Theme.of(context).platform == TargetPlatform.android)
              IconButton.filledTonal(
                tooltip: 'Switch camera',
                onPressed: _controller.switchCamera,
                icon: const Icon(Icons.cameraswitch),
              ),
            _hangUpButton(context, tooltip: 'Hang up'),
          ],
        ),
      ],
    );
  }

  Widget _hangUpButton(BuildContext context, {required String tooltip}) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton.filled(
      tooltip: tooltip,
      style: IconButton.styleFrom(backgroundColor: scheme.error),
      onPressed: _controller.hangUp,
      icon: Icon(Icons.call_end, color: scheme.onError),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
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

class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.children});
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

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
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

class _RelayStatusChip extends StatelessWidget {
  const _RelayStatusChip({required this.status});
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
class _SafetyNumber extends StatelessWidget {
  const _SafetyNumber({required this.number});
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

String _titleLabel(CallController controller, CallState call) =>
    switch (call.phase) {
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
      CallPhase.ended => 'Call ended (${_shortEnd(call.endReason)})',
    };

String _shortEnd(CallEndReason? reason) => switch (reason) {
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

String _describeEnd(CallState call) => switch (call.endReason) {
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

String _describeLinkError(InvalidIdentityException e) => switch (e.message) {
  'that is your own call link' => 'That is your own call link.',
  _ => 'That is not a valid Sotto call link.',
};
