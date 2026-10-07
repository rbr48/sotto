import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../call/call_controller.dart';
import '../../call/call_manager.dart';
import '../../call/ui/common.dart';
import '../../relay/relay_client.dart';
import '../guest_link.dart';
import '../guest_visit.dart';

/// What a client sees after opening a guest link in a browser: check camera
/// and microphone, knock, wait to be admitted, then the call.
class GuestPage extends StatefulWidget {
  const GuestPage({super.key, required this.controller});

  final CallController controller;

  @override
  State<GuestPage> createState() => _GuestPageState();
}

class _GuestPageState extends State<GuestPage> {
  CallController get _controller => widget.controller;
  final _nameField = TextEditingController();
  final _preview = RTCVideoRenderer();
  MediaStream? _previewStream;
  bool _previewReady = false;
  String? _deviceError;
  bool _checkingDevices = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
    unawaited(_startPreview());
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _ticker?.cancel();
    unawaited(_stopPreview());
    _preview.dispose();
    _nameField.dispose();
    super.dispose();
  }

  void _onChanged() {
    // Re-open the preview when the guest is back at the device check.
    final visit = _controller.guestVisit;
    if (visit?.phase == GuestVisitPhase.preparing && !_controller.call.active) {
      if (_previewStream == null && !_checkingDevices) {
        unawaited(_startPreview());
      }
    }
  }

  Future<void> _startPreview() async {
    setState(() {
      _checkingDevices = true;
      _deviceError = null;
    });
    try {
      if (!_previewReady) {
        await _preview.initialize();
        _previewReady = true;
      }
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {'facingMode': 'user'},
      });
      _previewStream = stream;
      _preview.srcObject = stream;
    } catch (e) {
      _deviceError =
          'Sotto could not use your camera or microphone. Allow access in your '
          "browser (usually the icon in the address bar), then press "
          '"Check again".';
    }
    if (mounted) setState(() => _checkingDevices = false);
  }

  Future<void> _stopPreview() async {
    final stream = _previewStream;
    _previewStream = null;
    if (_previewReady) _preview.srcObject = null;
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  Future<void> _knock({required bool video}) async {
    // Free the camera; the call opens it again once we are admitted.
    await _stopPreview();
    _controller.dismiss();
    _controller.guestVisit?.knock(name: _nameField.text, video: video);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final (title, body) = _content(context);
        return Title(
          title: 'Sotto · $title',
          color: Theme.of(context).colorScheme.primary,
          child: Scaffold(
            appBar: AppBar(
              title: Text(_hostName.isEmpty ? 'Sotto' : 'Call with $_hostName'),
              actions: [RelayStatusChip(status: _controller.relayStatus)],
            ),
            body: SafeArea(
              child: Column(
                children: [
                  Expanded(child: body),
                  const _SecuredFooter(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String get _hostName => _controller.guestVisit?.link.hostName ?? '';

  (String, Widget) _content(BuildContext context) {
    final theme = Theme.of(context);
    if (_controller.startupError case final error?) {
      return ('Error', Centered(child: Text('Sotto could not start: $error')));
    }
    if (!_controller.ready) {
      return ('Loading', const Centered(child: CircularProgressIndicator()));
    }
    if (_controller.guestLinkProblem case final problem?) {
      return (
        problem == GuestLinkProblem.expired ? 'Link expired' : 'Link not valid',
        _Message(
          icon: Icons.link_off,
          title: problem == GuestLinkProblem.expired
              ? 'This link has expired'
              : 'This link is not valid',
          text: 'Please ask for a new link.',
        ),
      );
    }
    final visit = _controller.guestVisit!;
    final call = _controller.call;

    if (call.phase == CallPhase.connecting ||
        call.phase == CallPhase.connected) {
      return (
        call.phase == CallPhase.connected ? 'Connected' : 'Connecting…',
        InCallView(controller: _controller),
      );
    }
    if (call.phase == CallPhase.ended &&
        visit.phase == GuestVisitPhase.admitted) {
      return (
        'Call ended (${shortEndReason(call.endReason)})',
        _Message(
          icon: Icons.call_end,
          title: 'Call ended',
          text: describeEnd(call),
          action: FilledButton(
            onPressed: visit.reset,
            child: const Text('Join again'),
          ),
        ),
      );
    }

    switch (visit.phase) {
      case GuestVisitPhase.declined:
        final (title, text) = switch (visit.declineReason) {
          'revoked' || 'unknown' => (
            'This link is no longer valid',
            'Please ask $_hostName for a new link.',
          ),
          'used' => (
            'This link was already used',
            'Please ask $_hostName for a new link.',
          ),
          'expired' => (
            'This link has expired',
            'Please ask $_hostName for a new link.',
          ),
          'full' => (
            'The waiting room is full',
            'Please try again in a few minutes.',
          ),
          _ => (
            '$_hostName can\'t take your call right now',
            'You can try again later.',
          ),
        };
        return (
          'Declined (${visit.declineReason ?? 'declined'})',
          _Message(
            icon: Icons.block,
            title: title,
            text: text,
            action:
                visit.declineReason == 'declined' ||
                    visit.declineReason == 'full'
                ? OutlinedButton(
                    onPressed: visit.reset,
                    child: const Text('Try again'),
                  )
                : null,
          ),
        );
      case GuestVisitPhase.waiting || GuestVisitPhase.admitted:
        final since = visit.waitingSince;
        final minutes = since == null
            ? 0
            : DateTime.now().difference(since).inMinutes;
        return (
          'Waiting to be let in',
          Centered(
            child: Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  'Waiting for $_hostName to let you in…',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _controller.relayStatus == RelayStatus.online
                      ? (minutes < 1 ? 'Just now' : 'Waiting $minutes min')
                      : 'Reconnecting…',
                  style: theme.textTheme.bodyMedium,
                ),
                if (visit.hostMessage case final message?) ...[
                  const SizedBox(height: 24),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: Text(message),
                      subtitle: Text(_hostName),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: visit.leave,
                  child: const Text('Leave'),
                ),
              ],
            ),
          ),
        );
      case GuestVisitPhase.preparing:
        return ('Check your camera', _buildDeviceCheck(context));
    }
  }

  Widget _buildDeviceCheck(BuildContext context) {
    final theme = Theme.of(context);
    return Centered(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: SottoLogo(size: 56)),
          const SizedBox(height: 16),
          Text(
            _hostName.isEmpty
                ? 'Join the call'
                : 'Join your call with $_hostName',
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ColoredBox(
                color: Colors.black,
                child: _previewStream != null
                    ? RTCVideoView(
                        _preview,
                        mirror: true,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      )
                    : Center(
                        child: _checkingDevices
                            ? const CircularProgressIndicator()
                            : const Icon(
                                Icons.videocam_off,
                                color: Colors.white54,
                                size: 48,
                              ),
                      ),
              ),
            ),
          ),
          if (_deviceError case final error?) ...[
            const SizedBox(height: 12),
            Text(error, style: TextStyle(color: theme.colorScheme.error)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _startPreview,
                child: const Text('Check again'),
              ),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _nameField,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Your name (optional)',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _previewStream == null
                    ? null
                    : () => _knock(video: true),
                icon: const Icon(Icons.videocam),
                label: const Text('Join with video'),
              ),
              OutlinedButton.icon(
                onPressed: _previewStream == null
                    ? null
                    : () => _knock(video: false),
                icon: const Icon(Icons.call),
                label: const Text('Join with voice only'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.text,
    this.action,
  });

  final IconData icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Centered(
      child: Column(
        children: [
          Icon(icon, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            title,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center),
          if (action case final action?) ...[
            const SizedBox(height: 24),
            action,
          ],
        ],
      ),
    );
  }
}

class _SecuredFooter extends StatelessWidget {
  const _SecuredFooter();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.lock,
          size: 14,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(width: 6),
        Text(
          'Secured by Sotto · end-to-end encrypted · nothing is stored',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}
