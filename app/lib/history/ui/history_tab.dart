import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../call/call_controller.dart';
import '../../call/ui/common.dart';
import '../../contacts/ui/contact_dialogs.dart';
import '../call_history.dart';

/// Calls on this device, with private session notes.
class HistoryTab extends StatelessWidget {
  const HistoryTab({super.key, required this.app, required this.calls});

  final AppController app;
  final CallController calls;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.history, app.contacts]),
      builder: (context, _) {
        final entries = app.history.entries;
        final days = app.history.retentionDays;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(switch (days) {
              0 => 'Call history is off (see Settings).',
              null => 'Calls are kept on this device until you delete them.',
              _ =>
                'Calls are kept on this device only, and deleted after $days days.',
            }, style: theme.textTheme.bodySmall),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Text('No calls yet.', textAlign: TextAlign.center),
              ),
            for (final entry in entries)
              ListTile(
                leading: Icon(
                  entry.missed
                      ? Icons.call_missed
                      : entry.outgoing
                      ? Icons.call_made
                      : Icons.call_received,
                  color: entry.missed ? theme.colorScheme.error : null,
                ),
                title: Text(_displayName(app, entry)),
                subtitle: Text(_summary(context, entry)),
                trailing: entry.note.isEmpty
                    ? null
                    : const Icon(
                        Icons.sticky_note_2_outlined,
                        semanticLabel: 'Has a note',
                      ),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) =>
                      CallDetailsDialog(app: app, calls: calls, id: entry.id),
                ),
              ),
            if (entries.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _confirmClear(context),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Delete all history'),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all call history and notes?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok ?? false) await app.history.clear();
  }
}

String _summary(BuildContext context, CallRecord entry) {
  final local = entry.startedAt.toLocal();
  final now = DateTime.now();
  final time = TimeOfDay.fromDateTime(local).format(context);
  final day =
      local.year == now.year && local.month == now.month && local.day == now.day
      ? 'Today'
      : '${local.day}/${local.month}/${local.year}';
  return [
    '$day $time',
    if (entry.duration case final d?) formatDuration(d),
    if (entry.duration == null) shortEndReason(entry.endReason),
    entry.video ? 'video' : 'voice',
    if (entry.autoAnswered) 'auto-answered',
  ].join(' · ');
}

/// One call: details, note, call back, add to contacts, delete.
class CallDetailsDialog extends StatefulWidget {
  const CallDetailsDialog({
    super.key,
    required this.app,
    required this.calls,
    required this.id,
  });

  final AppController app;
  final CallController calls;
  final String id;

  @override
  State<CallDetailsDialog> createState() => _CallDetailsDialogState();
}

class _CallDetailsDialogState extends State<CallDetailsDialog> {
  late final CallRecord? _entry = widget.app.history.find(widget.id);
  late final _note = TextEditingController(text: _entry?.note ?? '');

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _saveNote() => widget.app.history.setNote(widget.id, _note.text);

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    if (entry == null) return const SizedBox.shrink();
    final peer = entry.peer;
    final isContact = peer != null && widget.app.contacts.find(peer) != null;
    return AlertDialog(
      title: Text(_displayName(widget.app, entry)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_summary(context, entry)),
              const SizedBox(height: 16),
              TextField(
                controller: _note,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Session note (private, on this device only)',
                  alignLabelWithHint: true,
                ),
              ),
              if (peer != null) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final navigator = Navigator.of(context);
                        await _saveNote();
                        navigator.pop();
                        await widget.calls.callPeer(peer, video: entry.video);
                      },
                      icon: const Icon(Icons.call),
                      label: const Text('Call back'),
                    ),
                    if (!isContact)
                      OutlinedButton.icon(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => AddContactDialog(
                            safetyNumber: widget.calls.safetyNumberWith(peer),
                            name: _claimedName(entry.name),
                            onSave: (name, org, verified) =>
                                widget.app.contacts.add(
                                  peer,
                                  name: name.trim().isEmpty ? 'Contact' : name,
                                  organisation: org,
                                  verified: verified,
                                ),
                          ),
                        ).then((_) => setState(() {})),
                        icon: const Icon(Icons.person_add_alt),
                        label: const Text('Add to contacts'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final navigator = Navigator.of(context);
            await widget.app.history.remove(widget.id);
            navigator.pop();
          },
          child: const Text('Delete'),
        ),
        FilledButton(
          onPressed: () async {
            final navigator = Navigator.of(context);
            await _saveNote();
            navigator.pop();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Who a call was with: the contact's current name if they are (now) a
/// contact, otherwise the name saved when the call ended.
String _displayName(AppController app, CallRecord entry) {
  final peer = entry.peer;
  final contact = peer == null ? null : app.contacts.find(peer);
  return contact?.label ?? entry.name;
}

/// The name to suggest when adding the person as a contact.
String _claimedName(String saved) {
  const suffix = ' (not in your contacts)';
  if (saved == 'Unknown caller') return '';
  return saved.endsWith(suffix)
      ? saved.substring(0, saved.length - suffix.length)
      : saved;
}
