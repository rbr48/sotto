import 'dart:async';

import 'package:flutter/material.dart';

import '../../contacts/contact_link.dart';
import '../../crypto/identity.dart';
import '../../relay/relay_client.dart';
import '../call_controller.dart';
import '../call_manager.dart';
import 'call_screen.dart';
import 'common.dart';

/// A call from a browser, opened from someone's call link (`?call=`, dials
/// right away) or contact link (`#c=`, shows who it is first). Uses a
/// temporary identity; nothing is stored.
class QuickCallPage extends StatefulWidget {
  const QuickCallPage({
    super.key,
    required this.controller,
    required this.link,
    this.dialImmediately = false,
  });

  final CallController controller;
  final String link;
  final bool dialImmediately;

  @override
  State<QuickCallPage> createState() => _QuickCallPageState();
}

class _QuickCallPageState extends State<QuickCallPage> {
  CallController get _controller => widget.controller;
  late bool _dialPending = widget.dialImmediately;
  ContactInvite? _invite;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChange);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (_invite == null && _controller.ready) {
      try {
        _invite = ContactLink.parse(_controller.sodium!, widget.link);
      } on InvalidIdentityException {
        _error = 'This link is not valid. Ask for a new one.';
        _dialPending = false;
      }
    }
    if (_dialPending && _controller.relayStatus == RelayStatus.online) {
      _dialPending = false;
      unawaited(_call(video: true));
    }
  }

  Future<void> _call({required bool video}) async {
    final invite = _invite;
    if (invite == null) return;
    try {
      await _controller.callPeer(invite.identity, video: video);
    } on InvalidIdentityException {
      setState(() => _error = 'That is your own link.');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => Title(
      title: 'Sotto · ${callTitleLabel(_controller)}',
      color: Theme.of(context).colorScheme.primary,
      child: Scaffold(
        appBar: _controller.call.active
            ? null
            : AppBar(
                title: const Text('Sotto'),
                actions: [RelayStatusChip(status: _controller.relayStatus)],
              ),
        body: SafeArea(child: _body(context)),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    if (_controller.startupError case final error?) {
      return Centered(child: Text('Sotto could not start: $error'));
    }
    if (!_controller.ready) {
      return const Centered(child: CircularProgressIndicator());
    }
    final call = _controller.call;
    if (call.active) return CallScreen(controller: _controller);
    final invite = _invite;
    final name = invite?.name == null
        ? 'this person'
        : [invite!.name!, ?invite.organisation].join(', ');
    return Centered(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (call.phase == CallPhase.ended) ...[
            Card(
              color: theme.colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.call_end),
                title: Text(describeEnd(call)),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_error case final error?)
            Text(error, style: TextStyle(color: theme.colorScheme.error))
          else ...[
            Text('Call $name', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
              'End-to-end encrypted, from this browser. Nothing is kept '
              'after you close this tab. Colleagues with the Sotto app: '
              'paste this link in Contacts, Add contact.',
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
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Hide my IP address'),
              subtitle: const Text(
                'Route the call through the Sotto server so the other person '
                'never sees your IP address.',
              ),
              value: _controller.hideIp,
              onChanged: _controller.setHideIp,
            ),
          ],
        ],
      ),
    );
  }
}
