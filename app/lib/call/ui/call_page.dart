import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../crypto/identity.dart';
import '../../relay/relay_client.dart';
import '../call_controller.dart';
import '../../guest/guest_host.dart';
import '../call_manager.dart';
import 'common.dart';

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
              actions: [RelayStatusChip(status: _controller.relayStatus)],
            ),
            body: SafeArea(child: _buildBody(context, call)),
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, CallState call) {
    if (_controller.startupError case final error?) {
      return Centered(child: Text('Sotto could not start: $error'));
    }
    if (!_controller.ready) {
      return const Centered(child: CircularProgressIndicator());
    }
    return switch (call.phase) {
      CallPhase.idle || CallPhase.ended => _buildHome(context, call),
      CallPhase.calling || CallPhase.ringing => _buildOutgoing(context, call),
      CallPhase.incoming => _buildIncoming(context, call),
      CallPhase.connecting || CallPhase.connected => Stack(
        children: [
          Positioned.fill(child: InCallView(controller: _controller)),
          if (_controller.guestHost?.waiting.length case final n? when n > 0)
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

  Widget _buildHome(BuildContext context, CallState call) {
    final theme = Theme.of(context);
    return Centered(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_controller.guestHost case final host?
              when host.waiting.isNotEmpty) ...[
            _WaitingRoom(controller: _controller, host: host),
            const SizedBox(height: 16),
          ],
          if (call.phase == CallPhase.ended) ...[
            Card(
              color: theme.colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.call_end),
                title: Text(describeEnd(call)),
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
          _GuestLinks(controller: _controller),
          const SizedBox(height: 32),
          Text('Your direct call link', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'For colleagues: anyone with this link can ring you directly, without '
            'a waiting room. Calls are end-to-end encrypted.',
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
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hide my IP address'),
            subtitle: Text(
              _controller.hideIp &&
                      !_controller.turnAvailable &&
                      _controller.relayStatus == RelayStatus.online
                  ? 'This server has no TURN relay, so calls will fail while this is on.'
                  : 'Route calls through the Sotto server so the other person never sees '
                        'your IP address. Adds a little delay.',
            ),
            value: _controller.hideIp,
            onChanged: _controller.setHideIp,
          ),
          const SizedBox(height: 24),
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
                child: Pill(
                  text: call.phase == CallPhase.ringing
                      ? 'Ringing…'
                      : 'Calling… (waiting for their device)',
                ),
              ),
            ],
          ),
        ),
        ControlBar(
          children: [HangUpButton(controller: _controller, tooltip: 'Cancel')],
        ),
      ],
    );
  }

  Widget _buildIncoming(BuildContext context, CallState call) {
    final theme = Theme.of(context);
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
          const SizedBox(height: 16),
          if (_controller.safetyNumber case final number?)
            SafetyNumberBadge(number: number),
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
      CallPhase.ended => 'Call ended (${shortEndReason(call.endReason)})',
    };

String _describeLinkError(InvalidIdentityException e) => switch (e.message) {
  'that is your own call link' => 'That is your own call link.',
  _ => 'That is not a valid Sotto call link.',
};

/// Guests knocking on the professional's links.
class _WaitingRoom extends StatelessWidget {
  const _WaitingRoom({required this.controller, required this.host});

  final CallController controller;
  final GuestHost host;

  static const _quickReplies = [
    "I'll be with you in 5 minutes.",
    'Running a little late, please wait.',
    "I'm finishing another call. Thanks for waiting.",
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Waiting room (${host.waiting.length})',
                style: theme.textTheme.titleMedium,
              ),
            ),
            for (final guest in host.waiting)
              ListTile(
                leading: Icon(guest.video ? Icons.videocam : Icons.call),
                title: Text(guest.name),
                subtitle: Text(
                  'Waiting since ${TimeOfDay.fromDateTime(guest.since.toLocal()).format(context)}',
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    PopupMenuButton<String>(
                      tooltip: 'Send a message',
                      icon: const Icon(Icons.chat_bubble_outline),
                      onSelected: (text) => host.message(guest.knockId, text),
                      itemBuilder: (context) => [
                        for (final reply in _quickReplies)
                          PopupMenuItem(value: reply, child: Text(reply)),
                      ],
                    ),
                    TextButton(
                      onPressed: () => host.decline(guest.knockId),
                      child: const Text('Decline'),
                    ),
                    FilledButton(
                      onPressed: controller.call.active
                          ? null
                          : () => controller.admitGuest(guest.knockId),
                      child: const Text('Admit'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The professional's guest links: personal (reusable) and one-time.
class _GuestLinks extends StatefulWidget {
  const _GuestLinks({required this.controller});

  final CallController controller;

  @override
  State<_GuestLinks> createState() => _GuestLinksState();
}

class _GuestLinksState extends State<_GuestLinks> {
  late final _nameField = TextEditingController(
    text: widget.controller.hostName,
  );

  @override
  void dispose() {
    _nameField.dispose();
    super.dispose();
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final personal = controller.personalGuestLink;
    final linkStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Guest links', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Send a link to a client. They join from any browser, without an app '
          'or account, and wait until you admit them.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _nameField,
          decoration: const InputDecoration(
            labelText: 'Your name, as guests will see it',
          ),
          onChanged: controller.setHostName,
        ),
        const SizedBox(height: 12),
        if (personal != null)
          Row(
            children: [
              const Icon(Icons.link),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(personal, maxLines: 1, style: linkStyle),
              ),
              IconButton(
                tooltip: 'Copy personal link',
                icon: const Icon(Icons.copy),
                onPressed: () => _copy(personal),
              ),
              IconButton(
                tooltip: 'Replace personal link (the old one stops working)',
                icon: const Icon(Icons.autorenew),
                onPressed: controller.rotatePersonalGuestLink,
              ),
            ],
          ),
        for (final link in controller.oneTimeGuestLinks)
          Row(
            children: [
              const Icon(Icons.looks_one_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(link.url, maxLines: 1, style: linkStyle),
              ),
              IconButton(
                tooltip: 'Copy one-time link',
                icon: const Icon(Icons.copy),
                onPressed: () => _copy(link.url),
              ),
              IconButton(
                tooltip: 'Revoke one-time link',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => controller.revokeGuestLink(link.record.id),
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: controller.createOneTimeGuestLink,
            icon: const Icon(Icons.add_link),
            label: const Text('Create one-time link'),
          ),
        ),
      ],
    );
  }
}
