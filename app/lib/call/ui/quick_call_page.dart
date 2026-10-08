import 'dart:async';

import 'package:flutter/material.dart';

import '../../contacts/contact_link.dart';
import '../../core/ui_kit.dart';
import '../../crypto/identity.dart';
import '../../relay/relay_client.dart';
import '../call_controller.dart';
import '../call_manager.dart';
import 'call_screen.dart';
import 'common.dart';
import 'visitor_app_bar.dart';

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
            : VisitorAppBar(status: _controller.relayStatus),
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
    final name = invite?.name;
    final organisation = invite?.organisation;
    final ended = call.phase == CallPhase.ended;
    return Centered(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ended) ...[
            NoticeCard(
              tone: call.endReason == CallEndReason.failed
                  ? NoticeTone.warning
                  : NoticeTone.info,
              icon: call.endReason == CallEndReason.failed
                  ? Icons.error_outline
                  : Icons.call_end,
              title: call.endReason == CallEndReason.failed
                  ? 'The call didn\'t go through'
                  : 'Call ended',
              body: Text(
                call.endReason == CallEndReason.failed
                    ? call.error ?? 'Please try again.'
                    : describeEnd(call),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_error case final error?)
            NoticeCard(
              tone: NoticeTone.warning,
              icon: Icons.link_off,
              title: 'This link can\'t be used',
              body: Text(error),
            )
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: name == null
                          ? const IconBadge(icon: Icons.person, size: 80)
                          : InitialsAvatar(name: name, radius: 40),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      name == null ? 'Call this person' : 'Call $name',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                    if (organisation != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        organisation,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_outline,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'End-to-end encrypted',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _call(video: true),
                            icon: const Icon(Icons.videocam),
                            label: const Text('Video call'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _call(video: false),
                            icon: const Icon(Icons.call),
                            label: const Text('Voice call'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Divider(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Hide my IP address'),
                      subtitle: const Text(
                        'Route the call through the Sotto server so the '
                        'other person never sees your IP address.',
                      ),
                      value: _controller.hideIp,
                      onChanged: _controller.setHideIp,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Wrap(
              alignment: WrapAlignment.center,
              spacing: 20,
              runSpacing: 8,
              children: [
                _Point(icon: Icons.person_off_outlined, text: 'No account'),
                _Point(icon: Icons.download_done, text: 'No install'),
                _Point(icon: Icons.delete_outline, text: 'Nothing kept'),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Nothing is kept after you close this tab. Colleagues with the '
              'Sotto app: paste this link in Contacts, Add contact.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          text,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
