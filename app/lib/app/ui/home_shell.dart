import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../call/call_controller.dart';
import '../../call/call_manager.dart';
import '../../call/ui/common.dart';
import '../../chat/ui/chat_page.dart';
import '../../chat/ui/chats_tab.dart';
import '../../contacts/contact_book.dart';
import '../../contacts/contact_link.dart';
import '../../contacts/profile_exchange.dart';
import '../../contacts/ui/contact_dialogs.dart';
import '../../contacts/ui/contacts_tab.dart';
import '../../core/l10n/app_localizations.dart';
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

/// The professional's main screen: Home, Chats, Contacts, History and Settings.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.app, required this.calls});

  final AppController app;
  final CallController calls;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  int _unreadChatCount = 0;
  StreamSubscription<void>? _storeSub;

  static const _destinations = [
    (Icons.home_outlined, Icons.home),
    (Icons.chat_bubble_outline, Icons.chat_bubble),
    (Icons.people_outline, Icons.people),
    (Icons.history, Icons.history),
    (Icons.settings_outlined, Icons.settings),
  ];

  /// Tab labels in the current language.
  static String _label(AppLocalizations l10n, int i) => [
    l10n.navHome,
    l10n.navChats,
    l10n.navContacts,
    l10n.navHistory,
    l10n.navSettings,
  ][i];

  @override
  void initState() {
    super.initState();
    widget.calls.addListener(_onCallsChanged);
    _initChatListener();
  }

  @override
  void didUpdateWidget(HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.calls != widget.calls) {
      oldWidget.calls.removeListener(_onCallsChanged);
      widget.calls.addListener(_onCallsChanged);
      _storeSub?.cancel();
      _storeSub = null;
      _initChatListener();
    }
  }

  void _onCallsChanged() {
    if (_storeSub == null && widget.calls.chat != null) {
      _initChatListener();
    }
  }

  void _initChatListener() {
    final chat = widget.calls.chat;
    if (chat != null && _storeSub == null) {
      _storeSub = chat.store.changes.listen((_) => _refreshUnreadCount());
      unawaited(_refreshUnreadCount());
    }
  }

  Future<void> _refreshUnreadCount() async {
    final chat = widget.calls.chat;
    if (chat == null) return;
    final count = await chat.store.totalUnreadCount();
    if (mounted) setState(() => _unreadChatCount = count);
  }

  @override
  void dispose() {
    widget.calls.removeListener(_onCallsChanged);
    _storeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final app = widget.app;
    final calls = widget.calls;
    final tab = switch (_tab) {
      0 => HomeTab(app: app, calls: calls),
      1 => ChatsTab(app: app, calls: calls),
      2 => ContactsTab(app: app, calls: calls),
      3 => HistoryTab(app: app, calls: calls),
      _ => SettingsTab(app: app, calls: calls),
    };
    final body = Column(
      children: [
        if (app.availableUpdate case final update?)
          UpdateBanner(app: app, update: update, onLater: app.dismissUpdate),
        Expanded(child: tab),
      ],
    );
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final waiting = calls.guestHost?.waiting.length ?? 0;
    Widget icon(int index, bool selected) {
      final (outlined, filled) = _destinations[index];
      final widget = Icon(selected ? filled : outlined);
      if (index == 0 && waiting > 0) {
        return Badge(label: Text('$waiting'), child: widget);
      }
      if (index == 1 && _unreadChatCount > 0) {
        return Badge(label: Text('$_unreadChatCount'), child: widget);
      }
      return widget;
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
            message: l10n.navSettings,
            child: InkWell(
              onTap: () => setState(() => _tab = 4),
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
          if (kIsWeb) ...[HeaderDownloadsAction(), const SizedBox(width: 8)],
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
                          label: Text(_label(l10n, i)),
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
                    label: _label(l10n, i),
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
  ContactInvite? _previewInvite;
  Contact? _previewContact;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _linkField.addListener(_onLinkChanged);
  }

  void _onLinkChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      const Duration(milliseconds: 300),
      _checkLinkPreview,
    );
  }

  Future<void> _checkLinkPreview() async {
    final text = _linkField.text.trim();
    if (text.isEmpty) {
      if (mounted) {
        setState(() {
          _previewInvite = null;
          _previewContact = null;
        });
      }
      return;
    }
    try {
      final invite = await widget.calls.resolveLink(text);
      if (!mounted) return;
      final existing = widget.app.contacts.contacts
          .where((c) => c.identity.id == invite.identity.id)
          .firstOrNull;
      setState(() {
        _previewInvite = invite;
        _previewContact = existing;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _previewInvite = null;
          _previewContact = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _linkField.removeListener(_onLinkChanged);
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

  Future<void> _message() async {
    final text = _linkField.text.trim();
    if (text.isEmpty) {
      setState(() => _linkError = 'Please enter a contact link or call link.');
      return;
    }
    setState(() => _linkError = null);
    try {
      final invite = await widget.calls.resolveLink(text);
      if (invite.identity.id == widget.calls.ownId) {
        setState(() => _linkError = 'That is your own link.');
        return;
      }

      var contact = widget.app.contacts.contacts
          .where((c) => c.identity.id == invite.identity.id)
          .firstOrNull;

      if (contact == null && mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => AddContactDialog(
            safetyNumber: widget.calls.safetyNumberWith(invite.identity),
            name: invite.name ?? '',
            organisation: invite.organisation ?? '',
            onSave: (name, organisation, verified) async {
              await widget.app.contacts.add(
                invite.identity,
                name: name.trim().isEmpty ? 'Contact' : name,
                organisation: organisation,
                verified: verified,
              );
            },
          ),
        );
        contact = widget.app.contacts.contacts
            .where((c) => c.identity.id == invite.identity.id)
            .firstOrNull;
      }

      if (contact != null && mounted) {
        final chat = widget.calls.chat;
        if (chat != null) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ChatPage(
                chat: chat,
                contactId: contact!.identity.id,
                name: contact.name,
                sendTyping: widget.calls.sendTyping,
                sendReadReceipts: widget.calls.sendReadReceipts,
                verified: contact.verified,
                calls: widget.calls,
              ),
            ),
          );
        }
      }
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
    } catch (e) {
      setState(() => _linkError = '$e');
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
                    const IconBadge(icon: Icons.link_rounded),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Smart Link',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Connect with your health or legal contacts with end-to-end encryption.',
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
                    prefixIcon: const Icon(Icons.search_rounded),
                    labelText: 'Their link',
                    hintText: 'Search or paste…',
                    errorText: _linkError,
                  ),
                  onSubmitted: (_) => _call(video: true),
                ),
                if (_previewInvite case final invite?) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.25,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        InitialsAvatar(
                          name:
                              _previewContact?.name ?? invite.name ?? 'Contact',
                          radius: 14,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Real-time preview: ${_previewContact?.name ?? invite.name ?? 'Colleague'}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          (_previewContact?.verified ?? false)
                              ? Icons.verified
                              : Icons.shield_outlined,
                          color: const Color(0xFF10B981),
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          (_previewContact?.verified ?? false)
                              ? 'Verified'
                              : 'Secure',
                          style: const TextStyle(
                            color: Color(0xFF10B981),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => _call(video: true),
                  icon: const Icon(Icons.videocam_rounded),
                  label: const Text('Video Consultation'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _call(video: false),
                        icon: const Icon(Icons.call_rounded),
                        label: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('Voice Call'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _message,
                        icon: const Icon(Icons.chat_bubble_outline_rounded),
                        label: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('Chat'),
                        ),
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

/// Informs the user of an available update and offers in-app background
/// installation (or external download link when in-app update is unavailable).
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    super.key,
    required this.app,
    required this.update,
    required this.onLater,
  });

  final AppController app;
  final UpdateInfo update;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    if (app.isDownloadingUpdate) {
      final progress = app.updateProgress ?? 0.0;
      final percent = (progress * 100).toInt();
      return MaterialBanner(
        leading: const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Downloading Sotto ${update.version}... ($percent%)'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress > 0 ? progress : null),
          ],
        ),
        actions: [
          TextButton(
            onPressed: app.cancelUpdateDownload,
            child: const Text('Cancel'),
          ),
        ],
      );
    }

    if (app.downloadedUpdateFile != null) {
      return MaterialBanner(
        leading: const Icon(Icons.check_circle_outline, color: Colors.green),
        content: Text(
          'Sotto ${update.version} is downloaded and ready to install.',
        ),
        actions: [
          TextButton(onPressed: onLater, child: const Text('Later')),
          FilledButton(
            onPressed: app.applyUpdate,
            child: const Text('Restart to Update'),
          ),
        ],
      );
    }

    if (app.updateError != null) {
      return MaterialBanner(
        leading: const Icon(Icons.error_outline, color: Colors.red),
        content: Text('Update failed: ${app.updateError}'),
        actions: [
          TextButton(onPressed: onLater, child: const Text('Dismiss')),
          TextButton(
            onPressed: () =>
                launchUrl(update.url, mode: LaunchMode.externalApplication),
            child: const Text('Download Page'),
          ),
          FilledButton.tonal(
            onPressed: app.startUpdateDownload,
            child: const Text('Retry'),
          ),
        ],
      );
    }

    return MaterialBanner(
      leading: const Icon(Icons.system_update_alt),
      content: Text(
        'Sotto ${update.version} is available. You have $sottoVersion.',
      ),
      actions: [
        TextButton(onPressed: onLater, child: const Text('Not now')),
        if (update.canInstallInApp)
          FilledButton(
            onPressed: app.startUpdateDownload,
            child: const Text('Update Now'),
          )
        else
          FilledButton.tonal(
            onPressed: () =>
                launchUrl(update.url, mode: LaunchMode.externalApplication),
            child: const Text('Download'),
          ),
      ],
    );
  }
}
