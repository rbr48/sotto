import 'package:flutter/material.dart';

import '../../call/call_controller.dart';
import '../../call/call_manager.dart';
import '../../call/ui/common.dart';
import '../../contacts/ui/contact_dialogs.dart';
import '../../contacts/ui/contacts_tab.dart';
import '../../crypto/identity.dart';
import '../../guest/ui/host_widgets.dart';
import '../../history/ui/history_tab.dart';
import '../app_controller.dart';
import 'settings_tab.dart';

/// The professional's main screen: Home, Contacts, History and Settings.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.app, required this.calls});

  final AppController app;
  final CallController calls;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  static const _destinations = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.people_outline, Icons.people, 'Contacts'),
    (Icons.history, Icons.history, 'History'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final calls = widget.calls;
    final body = switch (_tab) {
      0 => HomeTab(app: app, calls: calls),
      1 => ContactsTab(app: app, calls: calls),
      2 => HistoryTab(app: app, calls: calls),
      _ => SettingsTab(app: app, calls: calls),
    };
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final waiting = calls.guestHost?.waiting.length ?? 0;
    Widget icon(int index, bool selected) {
      final (outlined, filled, _) = _destinations[index];
      final widget = Icon(selected ? filled : outlined);
      return index == 0 && waiting > 0
          ? Badge(label: Text('$waiting'), child: widget)
          : widget;
    }

    String initials(String name) {
      final parts = name.trim().split(RegExp(r'\s+'));
      if (parts.isEmpty || parts.first.isEmpty) return 'S';
      if (parts.length == 1) {
        return parts.first.characters.first.toUpperCase();
      }
      return '${parts.first.characters.first}${parts.last.characters.first}'
          .toUpperCase();
    }

    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8),
          child: Tooltip(
            message: 'Settings',
            child: InkWell(
              onTap: () => setState(() => _tab = 3),
              borderRadius: BorderRadius.circular(20),
              child: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                foregroundColor: theme.colorScheme.onPrimaryContainer,
                child: Text(
                  initials(app.profile?.name ?? 'Sotto'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (app.profile?.name case final name? when name.isNotEmpty) ...[
              Text(
                name,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (app.profile?.practice case final p? when p.isNotEmpty)
                Text(
                  p,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ] else ...[
              const SottoWordmark(height: 30),
            ],
          ],
        ),
        actions: [
          if (app.lock.hasPin)
            IconButton(
              tooltip: 'Lock Sotto',
              onPressed: app.lock.lock,
              icon: const Icon(Icons.lock_outline),
            ),
          RelayStatusChip(status: calls.relayStatus),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: wide
            ? Row(
                children: [
                  NavigationRail(
                    leading: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: SottoLogo(size: 36),
                    ),
                    selectedIndex: _tab,
                    onDestinationSelected: (i) => setState(() => _tab = i),
                    labelType: NavigationRailLabelType.all,
                    destinations: [
                      for (var i = 0; i < _destinations.length; i++)
                        NavigationRailDestination(
                          icon: icon(i, false),
                          selectedIcon: icon(i, true),
                          label: Text(_destinations[i].$3),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: _constrained(body)),
                ],
              )
            : _constrained(body),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                for (var i = 0; i < _destinations.length; i++)
                  NavigationDestination(
                    icon: icon(i, false),
                    selectedIcon: icon(i, true),
                    label: _destinations[i].$3,
                  ),
              ],
            ),
    );
  }

  Widget _constrained(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: child,
    ),
  );
}

/// Waiting room, the last call, guest links and calling a link.
class HomeTab extends StatefulWidget {
  const HomeTab({super.key, required this.app, required this.calls});

  final AppController app;
  final CallController calls;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  final _linkField = TextEditingController();
  String? _linkError;

  @override
  void dispose() {
    _linkField.dispose();
    super.dispose();
  }

  Future<void> _call({required bool video}) async {
    setState(() => _linkError = null);
    try {
      await widget.calls.callSomeone(_linkField.text, video: video);
    } on InvalidIdentityException catch (e) {
      setState(
        () => _linkError = e.message == 'that is your own call link'
            ? 'That is your own link.'
            : 'That is not a valid Sotto call link or contact link.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = widget.app;
    final calls = widget.calls;
    final call = calls.call;
    final trusted = app.contacts.trusted;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (calls.guestHost case final host? when host.waiting.isNotEmpty) ...[
          WaitingRoom(controller: calls, host: host),
          const SizedBox(height: 16),
        ],
        if (app.contacts.autoAnswerEnabled && trusted.isNotEmpty) ...[
          Card(
            color: theme.colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.phone_callback),
              title: const Text('Auto-answer is on'),
              subtitle: Text(
                'Calls from ${trusted.map((c) => c.name).join(', ')} '
                'connect by themselves after ${app.contacts.delaySeconds} s.',
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (call.phase == CallPhase.ended) ...[
          _LastCallCard(app: app, calls: calls),
          const SizedBox(height: 16),
        ],
        if (!app.persistent) ...[
          Card(
            color: theme.colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('These links work only while this tab is open'),
              subtitle: Text(
                app.canRememberInBrowser
                    ? 'Reloading or closing the tab creates new links. On '
                          'your own computer, let this browser remember you.'
                    : 'Reloading or closing the tab creates new links.',
              ),
              trailing: app.canRememberInBrowser
                  ? FilledButton.tonal(
                      onPressed: call.active ? null : app.rememberInBrowser,
                      child: const Text('Remember me'),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 16),
        ],
        GuestLinksCard(controller: calls, shownAs: app.profile?.label ?? ''),
        const SizedBox(height: 20),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.5,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.phone_forwarded_rounded,
                        color: theme.colorScheme.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Call a link',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Paste a colleague\'s contact link or call link. To call your contacts, use the Contacts tab.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('call-link-field'),
                  controller: _linkField,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.link_rounded),
                    labelText: 'Their link',
                    hintText: 'Paste call or contact link',
                    errorText: _linkError,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
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
          ),
        ),
      ],
    );
  }
}

/// How the last call ended, with a note and "add to contacts".
class _LastCallCard extends StatelessWidget {
  const _LastCallCard({required this.app, required this.calls});

  final AppController app;
  final CallController calls;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final call = calls.call;
    final historyId = calls.lastHistoryId;
    final hasEntry =
        historyId != null && app.history.find(historyId)?.id == call.callId;
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.call_end),
              title: Text(describeEnd(call)),
              subtitle: Text(calls.peerName),
            ),
            Wrap(
              spacing: 4,
              alignment: WrapAlignment.end,
              children: [
                if (hasEntry)
                  TextButton.icon(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => CallDetailsDialog(
                        app: app,
                        calls: calls,
                        id: historyId,
                      ),
                    ),
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Add note'),
                  ),
                if (calls.canAddPeerToContacts)
                  TextButton.icon(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => AddContactDialog(
                        safetyNumber: calls.safetyNumber,
                        onSave: (name, organisation, verified) =>
                            calls.addPeerToContacts(
                              name: name,
                              organisation: organisation,
                              verified: verified,
                            ),
                      ),
                    ),
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Add to contacts'),
                  ),
                TextButton(onPressed: calls.dismiss, child: const Text('OK')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
