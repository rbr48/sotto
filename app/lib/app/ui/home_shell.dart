import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../call/call_controller.dart';
import '../../call/call_manager.dart';
import '../../call/ui/common.dart';
import '../../contacts/profile_exchange.dart';
import '../../contacts/ui/contact_dialogs.dart';
import '../../contacts/ui/contacts_tab.dart';
import '../../core/ui_kit.dart';
import '../../core/update_check.dart';
import '../../core/version.dart';
import '../../crypto/identity.dart';
import '../../guest/ui/host_widgets.dart';
import '../../history/ui/history_tab.dart';
import '../../relay/relay_client.dart';
import '../app_controller.dart';
import 'header_downloads_action.dart';
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
    final tab = switch (_tab) {
      0 => HomeTab(app: app, calls: calls),
      1 => ContactsTab(app: app, calls: calls),
      2 => HistoryTab(app: app, calls: calls),
      _ => SettingsTab(app: app, calls: calls),
    };
    final body = Column(
      children: [
        if (app.availableUpdate case final update?)
          UpdateBanner(update: update, onLater: app.dismissUpdate),
        Expanded(child: tab),
      ],
    );
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

    final narrow = MediaQuery.sizeOf(context).width < 600;
    final (statusLabel, statusColor) = switch (calls.relayStatus) {
      RelayStatus.online => ('Online', const Color(0xFF16A34A)),
      RelayStatus.connecting => ('Connecting…', const Color(0xFFD97706)),
      RelayStatus.offline => ('Offline', theme.colorScheme.error),
    };
    final name = app.profile?.name ?? '';
    final practice = app.profile?.practice ?? '';

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        titleSpacing: 4,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Tooltip(
            message: 'Settings',
            child: InkWell(
              onTap: () => setState(() => _tab = 3),
              customBorder: const CircleBorder(),
              child: Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                      child: Text(
                        name.isEmpty ? 'S' : InitialsAvatar.initials(name),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.colorScheme.surface,
                            width: 2.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        leadingWidth: 60,
        title: name.isEmpty
            ? const SottoWordmark(height: 30)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    [
                      if (narrow) statusLabel,
                      if (practice.isNotEmpty) practice,
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
        actions: [
          if (app.lock.hasPin)
            IconButton(
              tooltip: 'Lock Sotto',
              onPressed: app.lock.lock,
              icon: const Icon(Icons.lock_outline),
            ),
          if (kIsWeb) ...[
            HeaderDownloadsAction(
              allDownloads: app.server.web.resolve('downloads.html'),
            ),
            const SizedBox(width: 8),
          ],
          if (narrow)
            const SizedBox(width: 8)
          else ...[
            RelayStatusChip(status: calls.relayStatus),
            const SizedBox(width: 8),
          ],
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
    } on ProfileUnavailableException {
      setState(
        () =>
            _linkError = 'They are not online right now. Try again in a while.',
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
          NoticeCard(
            tone: NoticeTone.success,
            icon: Icons.phone_callback,
            title: 'Auto-answer is on',
            body: Text(
              'Calls from ${trusted.map((c) => c.name).join(', ')} '
              'connect by themselves after ${app.contacts.delaySeconds} s.',
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (call.phase == CallPhase.ended) ...[
          _LastCallCard(app: app, calls: calls),
          const SizedBox(height: 16),
        ],
        if (!app.persistent) ...[
          NoticeCard(
            tone: NoticeTone.warning,
            icon: Icons.timer_outlined,
            title: 'These links work only while this tab is open',
            body: Text(
              app.canRememberInBrowser
                  ? 'Reloading or closing the tab creates new links. On '
                        'your own computer, let this browser remember you.'
                  : 'Reloading or closing the tab creates new links.',
            ),
            action: app.canRememberInBrowser
                ? FilledButton.tonal(
                    onPressed: call.active ? null : app.rememberInBrowser,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 40),
                    ),
                    child: const Text('Remember me'),
                  )
                : null,
          ),
          const SizedBox(height: 16),
        ],
        GuestLinksCard(controller: calls, shownAs: app.profile?.label ?? ''),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const IconBadge(icon: Icons.phone_forwarded_rounded),
                    const SizedBox(width: 14),
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
                  ),
                  onSubmitted: (_) => _call(video: true),
                ),
                const SizedBox(height: 16),
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: IconBadge(
                icon: Icons.call_end,
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
                        name: calls.call.peerClaimedName ?? '',
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

/// "Sotto 0.1.3 is available": opens the release page (the app never
/// downloads or installs anything by itself).
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.update, required this.onLater});

  final UpdateInfo update;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) => MaterialBanner(
    leading: const Icon(Icons.system_update_alt),
    content: Text(
      'Sotto ${update.version} is available. You have $sottoVersion.',
    ),
    actions: [
      TextButton(onPressed: onLater, child: const Text('Not now')),
      FilledButton.tonal(
        onPressed: () =>
            launchUrl(update.url, mode: LaunchMode.externalApplication),
        child: const Text('Download'),
      ),
    ],
  );
}
