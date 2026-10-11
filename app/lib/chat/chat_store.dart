import 'dart:async';
import 'dart:convert';

import 'dart:io';
import 'dart:typed_data';

import '../crypto/identity_store.dart';
import '../diagnostics/event_log.dart';
import 'chat_frames.dart';
import 'chat_group.dart';
import 'chat_groups.dart';
import 'file_storage.dart';

/// Where a message is. Outgoing: [sending] until stored on the other device
/// ([delivered]), [queued] in the client outbox waiting to send when online,
/// [read] when viewed by the recipient, or [notSent] when the session ended first.
/// Incoming: [received].
enum ChatState { sending, delivered, notSent, received, queued, read }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.contactId,
    required this.outgoing,
    required this.ts,
    required this.text,
    required this.state,
    this.reason,
    this.read = true,
    this.fileId,
    this.fileName,
    this.fileSize,
    this.fileMime,
    this.fileSha256,
    this.fileStatus,
    this.filePath,
    this.fileKey,
    this.arrivedAt,
    this.voiceNote = false,
    this.replyTo,
    this.reactions = const {},
    this.editedAt,
    this.deletedForAll = false,
    this.forwarded = false,
    this.starred = false,
    this.deliveredAt,
    this.readAt,
    this.groupId,
    this.authorId,
    this.memberStates = const {},
  }) : assert(groupId == null || groupId == contactId),
       assert(groupId == null || authorId != null);

  /// 16 random bytes, unpadded base64url. The same on both devices.
  final String id;

  /// The chat this message is in: the other person's Sotto ID, or for a group
  /// message the group's id, which [groupId] repeats.
  final String contactId;

  /// The group this message is in, or null for a one-to-one message.
  final String? groupId;

  /// The member who wrote the message: its Sotto ID. For a one-to-one message
  /// it is the contact, when the caller sets it. Null in records from before
  /// groups. Always set for a group message.
  final String? authorId;

  /// Each member's state for an outgoing group message, keyed by member id.
  /// Empty for a one-to-one message. For a group message, its status comes
  /// from these states alone: [state] stays `sending` and is never updated.
  final Map<String, ChatState> memberStates;

  final bool outgoing;

  /// The sender's clock, in milliseconds since the Unix epoch.
  final int ts;

  final String text;
  final ChatState state;

  /// Why the message was not sent: the chat's reason, such as 'no-answer'.
  /// Set only while [state] is [ChatState.notSent].
  final String? reason;

  /// Whether the message has been viewed. Outgoing messages are always true.
  /// Incoming messages start false until the chat is opened.
  final bool read;

  /// If this message represents a file transfer, its metadata.
  final String? fileId;
  final String? fileName;
  final int? fileSize;
  final String? fileMime;
  final String? fileSha256;
  final String? fileStatus;

  /// Where the received file is kept (see [ReceivedFileStore]).
  final String? filePath;

  /// The key that opens the file at [filePath]. It lives in this record, so
  /// deleting the message also makes the file unreadable.
  final String? fileKey;

  /// When an incoming message arrived on this device, in milliseconds since
  /// the epoch. Disappearing messages expire from this time, so a sender's
  /// clock cannot keep a message or purge it on arrival. Null for outgoing
  /// messages (their [ts] is this device's clock).
  final int? arrivedAt;

  /// Whether the file is a voice note: offered as one, and played in the
  /// bubble. A file that is only audio is an ordinary file.
  final bool voiceNote;

  /// The message this one replies to: its id and a copy of its text, so the
  /// quote still shows when the original is gone. Null for no reply.
  final ChatReply? replyTo;

  /// Reactions to this message, one emoji per person: "me" for this device's
  /// owner, "peer" for the contact. A person with no reaction has no key.
  final Map<String, String> reactions;

  /// When the text was last edited, in milliseconds since the epoch (the
  /// sender's clock for an edit by the contact). Null if never edited. No
  /// earlier text is kept.
  final int? editedAt;

  /// Whether the message was deleted for everyone. Its text is then empty, and
  /// the record is kept.
  final bool deletedForAll;

  /// Whether the text was forwarded from another chat.
  final bool forwarded;

  /// Whether this device's owner starred the message. Local only: never sent.
  final bool starred;

  /// When the other device first acknowledged the message, in milliseconds
  /// since the epoch. Null until then. Local only: never sent.
  final int? deliveredAt;

  /// When the contact first read the message, in milliseconds since the
  /// epoch. Null until then. Local only: never sent.
  final int? readAt;

  bool get isAttachment => fileName != null;

  /// This message's time on this device: [ts] for outgoing messages, and
  /// [arrivedAt] for incoming ones. It judges when the message expires, and the
  /// chat list and search order by it, so a peer's clock cannot change either.
  int get clockMs => outgoing ? ts : (arrivedAt ?? ts);

  /// The same message in another state. A reason is kept only when given.
  ChatMessage withState(ChatState next, {String? reason}) => ChatMessage(
    id: id,
    contactId: contactId,
    outgoing: outgoing,
    ts: ts,
    text: text,
    state: next,
    reason: reason,
    read: read,
    fileId: fileId,
    fileName: fileName,
    fileSize: fileSize,
    fileMime: fileMime,
    fileSha256: fileSha256,
    fileStatus: fileStatus,
    filePath: filePath,
    fileKey: fileKey,
    arrivedAt: arrivedAt,
    voiceNote: voiceNote,
    replyTo: replyTo,
    reactions: reactions,
    editedAt: editedAt,
    deletedForAll: deletedForAll,
    forwarded: forwarded,
    starred: starred,
    deliveredAt: deliveredAt,
    readAt: readAt,
    groupId: groupId,
    authorId: authorId,
    memberStates: memberStates,
  );

  /// The same message with [who]'s reaction set to [emoji]. [who] is "me" or
  /// "peer" in a one-to-one chat, and a member's id in a group. An empty emoji
  /// removes the reaction.
  ChatMessage withReaction(String who, String emoji) {
    final next = {...reactions};
    if (emoji.isEmpty) {
      next.remove(who);
    } else {
      next[who] = emoji;
    }
    return copyWith(reactions: next);
  }

  /// The same message with [member]'s state in [memberStates] set to [state].
  /// [state] of the message itself is left as it is.
  ChatMessage withMemberState(String member, ChatState state) =>
      copyWith(memberStates: {...memberStates, member: state});

  ChatMessage copyWith({
    String? id,
    String? contactId,
    bool? outgoing,
    int? ts,
    String? text,
    ChatState? state,
    String? reason,
    bool? read,
    String? fileId,
    String? fileName,
    int? fileSize,
    String? fileMime,
    String? fileSha256,
    String? fileStatus,
    String? filePath,
    String? fileKey,
    int? arrivedAt,
    bool? voiceNote,
    ChatReply? replyTo,
    Map<String, String>? reactions,
    int? editedAt,
    bool? deletedForAll,
    bool? forwarded,
    bool? starred,
    int? deliveredAt,
    int? readAt,
    String? groupId,
    String? authorId,
    Map<String, ChatState>? memberStates,
    bool clearReplyTo = false,
  }) => ChatMessage(
    id: id ?? this.id,
    contactId: contactId ?? this.contactId,
    outgoing: outgoing ?? this.outgoing,
    ts: ts ?? this.ts,
    text: text ?? this.text,
    state: state ?? this.state,
    reason: reason ?? this.reason,
    read: read ?? this.read,
    fileId: fileId ?? this.fileId,
    fileName: fileName ?? this.fileName,
    fileSize: fileSize ?? this.fileSize,
    fileMime: fileMime ?? this.fileMime,
    fileSha256: fileSha256 ?? this.fileSha256,
    fileStatus: fileStatus ?? this.fileStatus,
    filePath: filePath ?? this.filePath,
    fileKey: fileKey ?? this.fileKey,
    arrivedAt: arrivedAt ?? this.arrivedAt,
    voiceNote: voiceNote ?? this.voiceNote,
    replyTo: clearReplyTo ? null : (replyTo ?? this.replyTo),
    reactions: reactions ?? this.reactions,
    editedAt: editedAt ?? this.editedAt,
    deletedForAll: deletedForAll ?? this.deletedForAll,
    forwarded: forwarded ?? this.forwarded,
    starred: starred ?? this.starred,
    deliveredAt: deliveredAt ?? this.deliveredAt,
    readAt: readAt ?? this.readAt,
    groupId: groupId ?? this.groupId,
    authorId: authorId ?? this.authorId,
    memberStates: memberStates ?? this.memberStates,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'out': outgoing,
    'ts': ts,
    'text': text,
    'state': state.name,
    'reason': reason,
    'read': read,
    if (fileId != null) 'fileId': fileId,
    if (fileName != null) 'fileName': fileName,
    if (fileSize != null) 'fileSize': fileSize,
    if (fileMime != null) 'fileMime': fileMime,
    if (fileSha256 != null) 'fileSha256': fileSha256,
    if (fileStatus != null) 'fileStatus': fileStatus,
    if (filePath != null) 'filePath': filePath,
    if (fileKey != null) 'fileKey': fileKey,
    if (arrivedAt != null) 'arrivedAt': arrivedAt,
    if (voiceNote) 'voiceNote': true,
    if (replyTo case final quote?)
      'replyTo': {'id': quote.id, 'text': quote.text},
    if (reactions.isNotEmpty) 'reactions': reactions,
    if (editedAt != null) 'editedAt': editedAt,
    if (deletedForAll) 'deletedForAll': true,
    if (forwarded) 'forwarded': true,
    if (starred) 'starred': true,
    if (deliveredAt != null) 'deliveredAt': deliveredAt,
    if (readAt != null) 'readAt': readAt,
    if (groupId != null) 'groupId': groupId,
    if (authorId != null) 'authorId': authorId,
    if (memberStates.isNotEmpty)
      'memberStates': {
        for (final entry in memberStates.entries) entry.key: entry.value.name,
      },
  };

  /// The message stored as [json] in the chat with [contactId]: the contact's
  /// Sotto ID, or a group's id for a group message.
  static ChatMessage fromJson(String contactId, Map<String, dynamic> json) {
    final state = ChatState.values.where((s) => s.name == json['state']);
    final id = json['id'];
    final outgoing = json['out'];
    final ts = json['ts'];
    final text = json['text'];
    final reason = json['reason'];
    final read = json['read'];
    final fileId = json['fileId'];
    final fileName = json['fileName'];
    final fileSize = json['fileSize'];
    final fileMime = json['fileMime'];
    final fileSha256 = json['fileSha256'];
    final fileStatus = json['fileStatus'];
    final filePath = json['filePath'];
    final fileKey = json['fileKey'];
    final arrivedAt = json['arrivedAt'];
    final voiceNote = json['voiceNote'];
    final replyTo = _replyFrom(json['replyTo']);
    final reactions = _reactionsFrom(
      json['reactions'],
      group: json['groupId'] != null,
    );
    final editedAt = json['editedAt'];
    final deletedForAll = json['deletedForAll'];
    final forwarded = json['forwarded'];
    final starred = json['starred'];
    final deliveredAt = json['deliveredAt'];
    final readAt = json['readAt'];
    final groupId = json['groupId'];
    final authorId = json['authorId'];
    final memberStates = _memberStatesFrom(json['memberStates']);
    // A group message is kept under its group's id, and names it.
    final inGroup = groupId != null;
    if (id is! String ||
        outgoing is! bool ||
        ts is! int ||
        text is! String ||
        state.isEmpty ||
        (reason != null && reason is! String) ||
        (read != null && read is! bool) ||
        (fileId != null && fileId is! String) ||
        (fileName != null && fileName is! String) ||
        (fileSize != null && fileSize is! int) ||
        (fileMime != null && fileMime is! String) ||
        (fileSha256 != null && fileSha256 is! String) ||
        (fileStatus != null && fileStatus is! String) ||
        (filePath != null && filePath is! String) ||
        (fileKey != null && fileKey is! String) ||
        (arrivedAt != null && arrivedAt is! int) ||
        (voiceNote != null && voiceNote is! bool) ||
        (json['replyTo'] != null && replyTo == null) ||
        reactions == null ||
        (editedAt != null && editedAt is! int) ||
        (deletedForAll != null && deletedForAll is! bool) ||
        (forwarded != null && forwarded is! bool) ||
        (starred != null && starred is! bool) ||
        (deliveredAt != null && deliveredAt is! int) ||
        (readAt != null && readAt is! int) ||
        (inGroup && (groupId is! String || groupId != contactId)) ||
        (authorId != null && authorId is! String) ||
        (inGroup && !ChatGroups.isMemberId(authorId)) ||
        memberStates == null) {
      throw const ChatStoreException('unreadable');
    }
    return ChatMessage(
      id: id,
      contactId: contactId,
      outgoing: outgoing,
      ts: ts,
      text: text,
      state: state.first,
      reason: reason as String?,
      read: read is bool ? read : outgoing,
      fileId: fileId as String?,
      fileName: fileName as String?,
      fileSize: fileSize as int?,
      fileMime: fileMime as String?,
      fileSha256: fileSha256 as String?,
      fileStatus: fileStatus as String?,
      filePath: filePath as String?,
      fileKey: fileKey as String?,
      arrivedAt: arrivedAt as int?,
      voiceNote: voiceNote == true,
      replyTo: replyTo,
      reactions: reactions,
      editedAt: editedAt as int?,
      deletedForAll: deletedForAll == true,
      forwarded: forwarded == true,
      starred: starred == true,
      deliveredAt: deliveredAt as int?,
      readAt: readAt as int?,
      groupId: groupId as String?,
      authorId: authorId as String?,
      memberStates: memberStates,
    );
  }

  /// The quote stored as `replyTo`, or null when it is absent or not a quote.
  /// A present but malformed quote gives null too, and [fromJson] then refuses
  /// the record.
  static ChatReply? _replyFrom(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['id'];
    final text = raw['text'];
    if (id is! String || text is! String) return null;
    return (id: id, text: text);
  }

  /// The reactions stored as `reactions`: absent means none. Null when the
  /// value is not a map of emojis by reactor. A one-to-one message has "me" or
  /// "peer" as its reactors; a group message has member ids (see [withReaction]).
  static Map<String, String>? _reactionsFrom(
    Object? raw, {
    required bool group,
  }) {
    if (raw == null) return const {};
    if (raw is! Map) return null;
    final reactions = <String, String>{};
    for (final entry in raw.entries) {
      final who = entry.key;
      final emoji = entry.value;
      if (who is! String || !_isReactor(who, group: group)) return null;
      if (emoji is! String) return null;
      reactions[who] = emoji;
    }
    return reactions;
  }

  static bool _isReactor(String who, {required bool group}) =>
      group ? ChatGroups.isMemberId(who) : (who == 'me' || who == 'peer');

  /// The member states stored as `memberStates`: absent means none. Null when
  /// a member id or a state is not valid.
  static Map<String, ChatState>? _memberStatesFrom(Object? raw) {
    if (raw == null) return const {};
    if (raw is! Map) return null;
    final states = <String, ChatState>{};
    for (final entry in raw.entries) {
      final member = entry.key;
      final name = entry.value;
      if (member is! String || !ChatGroups.isMemberId(member)) return null;
      if (name is! String) return null;
      final match = ChatState.values.where((s) => s.name == name);
      if (match.isEmpty) return null;
      states[member] = match.first;
    }
    return states;
  }
}

/// The stored chats cannot be read. They are never overwritten: the app
/// explains the problem instead.
class ChatStoreException implements Exception {
  const ChatStoreException(this.reason);

  final String reason;

  @override
  String toString() => 'ChatStoreException: $reason';
}

/// What this device keeps about a chat: whether it is archived, muted and
/// pinned. Local only: never sent to the contact or the relay.
class ChatMeta {
  const ChatMeta({this.archived = false, this.muted = false, this.pinnedAt});

  /// The settings of a chat with no record: not archived, not muted, not
  /// pinned.
  static const defaults = ChatMeta();

  final bool archived;
  final bool muted;

  /// When the chat was pinned, in milliseconds since the epoch. Null when it
  /// is not pinned.
  final int? pinnedAt;

  bool get isDefault => !archived && !muted && pinnedAt == null;

  ChatMeta copyWith({
    bool? archived,
    bool? muted,
    int? pinnedAt,
    bool clearPinnedAt = false,
  }) => ChatMeta(
    archived: archived ?? this.archived,
    muted: muted ?? this.muted,
    pinnedAt: clearPinnedAt ? null : (pinnedAt ?? this.pinnedAt),
  );

  Map<String, Object?> toJson() => {
    'archived': archived,
    'muted': muted,
    'pinnedAt': pinnedAt,
  };

  /// The settings held as [raw]. A key that is absent takes its default. Null
  /// when a value has the wrong type.
  static ChatMeta? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final archived = raw['archived'] ?? false;
    final muted = raw['muted'] ?? false;
    final pinnedAt = raw['pinnedAt'];
    if (archived is! bool || muted is! bool) return null;
    if (pinnedAt != null && pinnedAt is! int) return null;
    return ChatMeta(
      archived: archived,
      muted: muted,
      pinnedAt: pinnedAt as int?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatMeta &&
      other.archived == archived &&
      other.muted == muted &&
      other.pinnedAt == pinnedAt;

  @override
  int get hashCode => Object.hash(archived, muted, pinnedAt);
}

/// The result of pinning a chat (see [ChatStore.setPinned]).
enum ChatPinResult { pinned, unpinned, limitReached }

/// An invite to a group that its invitee has not answered. The inviter keeps
/// it so the invite can be sent again until it expires. Local only.
final class PendingInvite {
  const PendingInvite({
    required this.group,
    required this.invitee,
    required this.attempts,
    required this.sentAt,
    required this.expiry,
  });

  /// The group's id.
  final String group;

  /// The invitee's Sotto ID.
  final String invitee;

  /// How many times the invite has been sent.
  final int attempts;

  /// When the invite was last sent, in milliseconds since the epoch.
  final int sentAt;

  /// When the invite stops being sent, in milliseconds since the epoch.
  final int expiry;

  Map<String, Object?> toJson() => {
    'group': group,
    'invitee': invitee,
    'attempts': attempts,
    'sentAt': sentAt,
    'expiry': expiry,
  };

  /// The invite stored as [raw] for [group]. Null when it is not a valid one.
  static PendingInvite? fromJson(String group, Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final invite = raw['group'];
    final invitee = raw['invitee'];
    final attempts = raw['attempts'];
    final sentAt = raw['sentAt'];
    final expiry = raw['expiry'];
    if (invite != group ||
        invitee is! String ||
        !ChatGroups.isMemberId(invitee) ||
        attempts is! int ||
        attempts < 0 ||
        sentAt is! int ||
        expiry is! int) {
      return null;
    }
    return PendingInvite(
      group: group,
      invitee: invitee,
      attempts: attempts,
      sentAt: sentAt,
      expiry: expiry,
    );
  }
}

/// The history of each chat, kept in the encrypted vault.
/// Conversations are stored per contact under separate keys (`sotto.chats.contact.<id>`),
/// with a directory index under `sotto.chats.contacts.v1`. Each chat also has a
/// summary (`sotto.chats.summary.<id>`) with its last message and unread count,
/// so the chat list does not read whole histories.
/// Legacy monolithic stores (`sotto.chats.v1`) are automatically migrated.
class ChatStore {
  ChatStore(
    this._store, {
    this.files,
    this.browserMemoryBytes = defaultBrowserMemoryBytes,
    void Function(String event)? log,
  }) : _log = log ?? EventLog.instance.add;

  /// Where problems with a chat's records are reported (the diagnostic report).
  /// Never a contact, an id or any text of a message.
  final void Function(String event) _log;

  /// The problems reported so far, by contact, so that a chat which stays
  /// broken is reported once, not on every change.
  final _reported = <String>{};

  void _report(String contactId, String problem) {
    if (_reported.add('$contactId $problem')) _log(problem);
  }

  /// Where received files are kept, encrypted. Null in the browser, which
  /// keeps none.
  final ReceivedFileStore? files;

  /// How many bytes of files and voice notes the browser holds at most.
  static const defaultBrowserMemoryBytes = 150 * 1024 * 1024;

  /// The most bytes of files the browser holds in memory. Past it, the files
  /// used least recently are let go, and show as no longer on this device.
  final int browserMemoryBytes;

  /// Files and voice notes the browser holds for the life of the tab, least
  /// recently used first. Keys are `f:<file id>` for files and `v:<message
  /// id>` for voice notes. Never in the vault or in browser storage, so a
  /// reload loses them.
  final _browserHeld = <String, Uint8List>{};

  /// The bytes in [_browserHeld], in all.
  int _browserHeldBytes = 0;

  /// The bytes of files and voice notes the browser holds now.
  int get browserHeldBytes => _browserHeldBytes;

  static String _fileKey(String id) => 'f:$id';
  static String _voiceKey(String id) => 'v:$id';

  void _hold(String key, Uint8List bytes) {
    _drop(key);
    _browserHeld[key] = bytes;
    _browserHeldBytes += bytes.length;
    // The oldest go first; the one just added always stays.
    while (_browserHeldBytes > browserMemoryBytes && _browserHeld.length > 1) {
      final oldest = _browserHeld.keys.first;
      if (oldest == key) break;
      _drop(oldest);
    }
  }

  /// The bytes held under [key], now the most recently used.
  Uint8List? _held(String key) {
    final bytes = _browserHeld.remove(key);
    if (bytes != null) _browserHeld[key] = bytes;
    return bytes;
  }

  void _drop(String key) {
    final bytes = _browserHeld.remove(key);
    if (bytes != null) _browserHeldBytes -= bytes.length;
  }

  /// Legacy storage key for monolithic chat storage.
  static const storageKey = 'sotto.chats.v1';

  /// Key for the list of contact IDs with stored messages.
  static const contactsIndexKey = 'sotto.chats.contacts.v1';

  /// Storage key for a specific contact's messages.
  static String contactKey(String contactId) =>
      'sotto.chats.contact.$contactId';

  /// Storage key for a contact's pending reactions, edits and deletes (see
  /// [queueControl]).
  static String pendingKey(String contactId) =>
      'sotto.chats.pending.$contactId';

  /// Storage key for a chat's summary: its last message as stored and its
  /// unread count. Written with every change to the chat's messages. The chat
  /// list trusts it without checking the messages, so a build that changes a
  /// chat without writing its summary leaves the list stale until that chat
  /// changes again. So one vault must not be shared with such a build
  /// (`docs/PROTOCOL.md`, section 9).
  static String summaryKey(String contactId) =>
      'sotto.chats.summary.$contactId';

  /// Storage key for a chat's settings: archived, muted and pinned (see
  /// [ChatMeta]). Absent means the defaults. The summary carries a copy, so
  /// the chat list does not read this key. A group's settings use the same key
  /// with its id, as its id is never a contact's.
  static String metaKey(String contactId) => 'sotto.chats.meta.$contactId';

  /// Key for the list of group ids on this device, in the order they were
  /// saved. Each group has a record ([groupKey]).
  static const groupsIndexKey = 'sotto.groups.v1';

  /// Storage key for a group's record (see [ChatGroup]).
  static String groupKey(String groupId) => 'sotto.groups.$groupId';

  /// Storage key for a group's messages, oldest first.
  static String groupMessagesKey(String groupId) =>
      'sotto.groups.msgs.$groupId';

  /// Storage key for a group's summary: its last message and unread count.
  /// Absent while the group has no messages.
  static String groupSummaryKey(String groupId) =>
      'sotto.groups.summary.$groupId';

  /// Storage key for a group's invites that are not answered yet (see
  /// [PendingInvite]).
  static String groupInvitesKey(String groupId) =>
      'sotto.groups.invites.$groupId';

  /// Storage key for the controls a group member is owed: reactions, edits and
  /// deletes of this device's messages in the group, waiting for the member's
  /// direct session (see [queueControl]).
  static String groupPendingKey(String groupId, String memberId) =>
      'sotto.groups.pending.$groupId.$memberId';

  /// Most chats that can be pinned at once.
  static const maxPinnedChats = 3;

  /// Most pending controls kept for one contact. Past this, the oldest is
  /// dropped, so a chat that stays offline for long cannot grow without limit.
  static const maxPendingControls = 100;

  final SecretStore _store;
  final _changes = StreamController<void>.broadcast();

  /// Emits whenever messages are added, updated, read, or deleted.
  Stream<void> get changes => _changes.stream;

  /// Cached contact index.
  Set<String>? _contactIndex;

  /// Cached group index (see [groupsIndexKey]).
  Set<String>? _groupIndex;

  /// In-memory cache of group ID -> record.
  final _cachedGroups = <String, ChatGroup>{};

  /// In-memory cache of contact ID, or group ID -> messages.
  final _cachedChats = <String, List<ChatMessage>>{};

  /// In-memory cache of contact ID -> settings (see [metaKey]).
  final _cachedMeta = <String, ChatMeta>{};

  bool _migrated = false;

  /// The last write asked for. Writes run one after another, in the order
  /// they were asked for, so a change asked for after a message is stored
  /// always lands after it (for example, marking it not sent).
  Future<void> _tail = Future<void>.value();

  Future<T> _inOrder<T>(Future<T> Function() write) {
    final result = _tail.then((_) => write());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _checkMigration() async {
    if (_migrated) return;
    final legacy = await _store.read(storageKey);
    if (legacy != null) {
      final Object? json;
      try {
        json = jsonDecode(legacy);
      } on FormatException {
        throw const ChatStoreException('unreadable');
      }
      if (json is! Map<String, dynamic>) {
        throw const ChatStoreException('unreadable');
      }
      final index = <String>{};
      for (final entry in json.entries) {
        final list = entry.value;
        if (list is! List) throw const ChatStoreException('unreadable');
        final messages = <ChatMessage>[];
        for (final item in list) {
          if (item is! Map<String, dynamic>) {
            throw const ChatStoreException('unreadable');
          }
          messages.add(ChatMessage.fromJson(entry.key, item));
        }
        if (messages.isNotEmpty) {
          index.add(entry.key);
          _cachedChats[entry.key] = messages;
          await _store.write(
            contactKey(entry.key),
            jsonEncode([for (final m in messages) m.toJson()]),
          );
        }
      }
      _contactIndex = index;
      await _store.write(contactsIndexKey, jsonEncode(index.toList()));
      await _store.delete(storageKey);
    }
    _migrated = true;
  }

  Future<Set<String>> _loadIndex() async {
    if (_contactIndex case final index?) return index;
    await _checkMigration();
    final raw = await _store.read(contactsIndexKey);
    if (raw == null) {
      return _contactIndex = <String>{};
    }
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! List) throw const ChatStoreException('unreadable');
    final index = <String>{};
    for (final item in json) {
      if (item is String) index.add(item);
    }
    return _contactIndex = index;
  }

  /// The messages of the chat with [contactId]: a contact's, or a group's when
  /// [contactId] is a group id (see [_isGroup]).
  Future<List<ChatMessage>> _loadContact(String contactId) async {
    if (_cachedChats[contactId] case final cached?) {
      return cached;
    }
    await _checkMigration();
    final group = await _isGroup(contactId);
    final raw = await _store.read(
      group ? groupMessagesKey(contactId) : contactKey(contactId),
    );
    if (raw == null) {
      return _cachedChats[contactId] = [];
    }
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! List) throw const ChatStoreException('unreadable');
    final messages = <ChatMessage>[];
    for (final item in json) {
      if (item is! Map<String, dynamic>) {
        throw const ChatStoreException('unreadable');
      }
      messages.add(ChatMessage.fromJson(contactId, item));
    }
    if (group && messages.any((m) => m.groupId != contactId)) {
      throw const ChatStoreException('unreadable');
    }
    return _cachedChats[contactId] = messages;
  }

  /// The group ids on this device, from the index.
  Future<Set<String>> _loadGroupIndex() async {
    if (_groupIndex case final index?) return index;
    await _checkMigration();
    final raw = await _store.read(groupsIndexKey);
    if (raw == null) {
      return _groupIndex = <String>{};
    }
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! List) throw const ChatStoreException('unreadable');
    final index = <String>{};
    for (final item in json) {
      if (item is String) index.add(item);
    }
    return _groupIndex = index;
  }

  /// Whether [scope] is a group's id, not a contact's. A chat is looked up by
  /// its scope: the contact's Sotto ID, or the group's id. A group must be
  /// saved ([saveGroup]) before its messages are stored.
  Future<bool> _isGroup(String scope) async =>
      (await _loadGroupIndex()).contains(scope);

  /// The record of the group [groupId], or null when there is none.
  Future<ChatGroup?> _loadGroup(String groupId) async {
    if (_cachedGroups[groupId] case final cached?) return cached;
    final raw = await _store.read(groupKey(groupId));
    if (raw == null) return null;
    return _cachedGroups[groupId] = _groupFrom(groupId, raw);
  }

  /// [_loadGroup], or null when the record cannot be read. The problem is
  /// reported once, and the group is left out of lists.
  Future<ChatGroup?> _tryLoadGroup(String groupId) async {
    try {
      return await _loadGroup(groupId);
    } on ChatStoreException {
      _report(groupId, 'group cannot be read');
      return null;
    }
  }

  /// The record of a group, as stored. Its member states are kept as they
  /// stand, so every device's own table is what is stored.
  static String _groupJson(ChatGroup group) => jsonEncode({
    'id': group.id,
    'name': group.name,
    'self': group.selfId,
    'createdAt': group.createdAt,
    'left': group.left,
    'members': [
      for (final member in group.members)
        {
          'id': member.id,
          'state': member.state.name,
          'invitedAt': member.invitedAt,
        },
    ],
  });

  /// The group stored as [raw] under [groupId]. Throws [ChatStoreException]
  /// when it does not hold a group that this code can read.
  static ChatGroup _groupFrom(String groupId, String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! Map<String, dynamic>) {
      throw const ChatStoreException('unreadable');
    }
    final id = json['id'];
    final name = json['name'];
    final self = json['self'];
    final createdAt = json['createdAt'];
    final left = json['left'];
    final members = json['members'];
    if (id != groupId ||
        !ChatFrames.isId(id) ||
        name is! String ||
        self is! String ||
        !ChatGroups.isMemberId(self) ||
        createdAt is! int ||
        left is! bool ||
        members is! List) {
      throw const ChatStoreException('unreadable');
    }
    final cleaned = ChatGroups.cleanName(name);
    if (cleaned != name ||
        name.isEmpty ||
        name.runes.length > maxGroupNameChars) {
      throw const ChatStoreException('unreadable');
    }
    final entries = <GroupMember>[];
    for (final item in members) {
      if (item is! Map<String, dynamic>) {
        throw const ChatStoreException('unreadable');
      }
      final member = item['id'];
      final state = item['state'];
      final invitedAt = item['invitedAt'];
      if (member is! String ||
          !ChatGroups.isMemberId(member) ||
          state is! String ||
          invitedAt is! int) {
        throw const ChatStoreException('unreadable');
      }
      final match = MemberState.values.where((s) => s.name == state);
      if (match.isEmpty) throw const ChatStoreException('unreadable');
      entries.add(
        GroupMember(id: member, state: match.first, invitedAt: invitedAt),
      );
    }
    final group = ChatGroup(
      id: groupId,
      name: name,
      selfId: self,
      createdAt: createdAt,
      members: entries,
    );
    final distinct = {for (final m in entries) m.id};
    if (distinct.length != entries.length ||
        group.memberOf(self) == null ||
        group.left != left) {
      throw const ChatStoreException('unreadable');
    }
    return group;
  }

  /// Saves [list] as the chat with [contactId], with its summary and the
  /// contact index, in one write, so they are stored together or not at all.
  /// The cache takes the new list only once it is stored, so a failed write
  /// leaves what is on screen equal to what is saved. Callers pass a copy of
  /// the cached list. A group's messages are saved the same way, without the
  /// index: a group is listed by its record, not by its messages.
  Future<void> _saveContact(String contactId, List<ChatMessage> list) async {
    if (await _isGroup(contactId)) {
      await _saveGroupMessages(contactId, list);
      return;
    }
    final index = await _loadIndex();
    final next = {...index};
    if (list.isNotEmpty) {
      next.add(contactId);
    } else {
      next.remove(contactId);
    }
    final indexChanged = next.length != index.length;
    final meta = await _metaOf(contactId);
    await _store.writeAll(
      {
        contactKey(contactId): jsonEncode([for (final m in list) m.toJson()]),
        if (list.isNotEmpty) summaryKey(contactId): _summaryJson(list, meta),
        if (indexChanged) contactsIndexKey: jsonEncode(next.toList()),
      },
      deleted: [if (list.isEmpty) summaryKey(contactId)],
    );
    _cachedChats[contactId] = list;
    if (indexChanged) _contactIndex = next;
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  /// Saves [list] as the messages of the group [groupId], with its summary, in
  /// one write. Called inside [_inOrder] by way of [_saveContact].
  Future<void> _saveGroupMessages(
    String groupId,
    List<ChatMessage> list,
  ) async {
    final meta = await _metaOf(groupId);
    await _store.writeAll(
      {
        if (list.isNotEmpty)
          groupMessagesKey(groupId): jsonEncode([
            for (final m in list) m.toJson(),
          ]),
        if (list.isNotEmpty) groupSummaryKey(groupId): _summaryJson(list, meta),
      },
      deleted: [
        if (list.isEmpty) ...[
          groupMessagesKey(groupId),
          groupSummaryKey(groupId),
        ],
      ],
    );
    _cachedChats[groupId] = list;
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  /// The summary record of [list]: its last message as stored, its unread
  /// count, and the chat's settings ([meta]).
  static String _summaryJson(List<ChatMessage> list, ChatMeta meta) =>
      jsonEncode({
        'last': list.last.toJson(),
        'unread': _unreadIn(list),
        'meta': meta.toJson(),
      });

  /// The settings of the chat with [contactId]: the defaults when it has no
  /// record. A record that cannot be read is reported and the defaults are
  /// used, so it never blocks the chat. The summary is then checked against
  /// these settings (see [threadSummary]), so the chat list shows the same.
  Future<ChatMeta> _metaOf(String contactId) async {
    if (_cachedMeta[contactId] case final cached?) return cached;
    final raw = await _store.read(metaKey(contactId));
    if (raw == null) return _cachedMeta[contactId] = ChatMeta.defaults;
    final meta = _metaFrom(raw);
    if (meta == null) {
      _report(contactId, 'chat settings cannot be read');
      return _cachedMeta[contactId] = ChatMeta.defaults;
    }
    return _cachedMeta[contactId] = meta;
  }

  static ChatMeta? _metaFrom(String raw) {
    try {
      return ChatMeta.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  /// Stores [next] as the settings of the chat with [contactId], with its
  /// summary, in one write. Called inside [_inOrder].
  Future<void> _writeMeta(String contactId, ChatMeta next) async {
    final list = await _loadContact(contactId);
    final summary = await _summaryKeyOf(contactId);
    await _store.writeAll(
      {
        if (!next.isDefault) metaKey(contactId): jsonEncode(next.toJson()),
        if (list.isNotEmpty) summary: _summaryJson(list, next),
      },
      deleted: [if (next.isDefault) metaKey(contactId)],
    );
    _cachedMeta[contactId] = next;
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  /// The settings of the chat with [contactId].
  Future<ChatMeta> chatMeta(String contactId) =>
      _inOrder(() => _metaOf(contactId));

  /// Archives or unarchives the chat with [contactId]. An archived chat is
  /// left out of the main chat list (see [archivedChats]).
  Future<void> setArchived(String contactId, bool archived) =>
      _changeMeta(contactId, (m) => m.copyWith(archived: archived));

  /// Whether the chat with [contactId] (or the group) is muted on this device.
  Future<bool> isMuted(String contactId) async =>
      (await _metaOf(contactId)).muted;

  /// Mutes or unmutes the chat with [contactId].
  Future<void> setMuted(String contactId, bool muted) =>
      _changeMeta(contactId, (m) => m.copyWith(muted: muted));

  Future<void> _changeMeta(
    String contactId,
    ChatMeta Function(ChatMeta current) change,
  ) => _inOrder(() async {
    final current = await _metaOf(contactId);
    final next = change(current);
    if (next != current) await _writeMeta(contactId, next);
  });

  /// Pins the chat with [contactId] at [at], or unpins it. A chat that is
  /// already pinned keeps its place. At most [maxPinnedChats] chats are
  /// pinned at once, archived ones included: past that a pin is refused with
  /// [ChatPinResult.limitReached], and nothing changes.
  Future<ChatPinResult> setPinned(
    String contactId,
    bool pinned, {
    required int at,
  }) => _inOrder(() async {
    final current = await _metaOf(contactId);
    if (!pinned) {
      if (current.pinnedAt != null) {
        await _writeMeta(contactId, current.copyWith(clearPinnedAt: true));
      }
      return ChatPinResult.unpinned;
    }
    if (current.pinnedAt != null) return ChatPinResult.pinned;
    if (await _pinnedCountExcept(contactId) >= maxPinnedChats) {
      return ChatPinResult.limitReached;
    }
    await _writeMeta(contactId, current.copyWith(pinnedAt: at));
    return ChatPinResult.pinned;
  });

  /// How many chats other than [contactId] are pinned, groups included. Called
  /// inside [_inOrder], so it reads the settings records, not the summaries (a
  /// summary read can itself wait for [_inOrder]).
  Future<int> _pinnedCountExcept(String contactId) async {
    var count = 0;
    for (final id in [...await _loadIndex(), ...await _loadGroupIndex()]) {
      if (id != contactId && (await _metaOf(id)).pinnedAt != null) count++;
    }
    return count;
  }

  /// The key of the summary record of the chat with [scope].
  Future<String> _summaryKeyOf(String scope) async =>
      (await _isGroup(scope)) ? groupSummaryKey(scope) : summaryKey(scope);

  /// Stores [group]: its record, and its place in the group index. Saving a
  /// group again replaces its record, which is how a change to its members is
  /// kept.
  Future<void> saveGroup(ChatGroup group) => _inOrder(() => _writeGroup(group));

  /// Changes the group [groupId] in one step. [change] gets the record as it
  /// is when this write runs, and returns the next record, or null for no
  /// change. Writes run in order, so two changes made at once each build on the
  /// other's result rather than overwriting it. Returns the record as it is
  /// after the call, or null when there is no such group and [change] made none.
  Future<ChatGroup?> updateGroup(
    String groupId,
    ChatGroup? Function(ChatGroup? current) change,
  ) => _inOrder(() async {
    final current = await _loadGroup(groupId);
    final next = change(current);
    if (next == null || identical(next, current)) return current;
    await _writeGroup(next);
    return next;
  });

  Future<void> _writeGroup(ChatGroup group) async {
    final index = await _loadGroupIndex();
    final next = {...index, group.id};
    await _store.writeAll({
      groupKey(group.id): _groupJson(group),
      if (next.length != index.length)
        groupsIndexKey: jsonEncode(next.toList()),
    });
    _cachedGroups[group.id] = group;
    if (next.length != index.length) _groupIndex = next;
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  /// The group with [groupId] on this device, or null when there is none.
  Future<ChatGroup?> group(String groupId) => _loadGroup(groupId);

  /// The groups on this device, in the order they were saved. A group that
  /// cannot be read is left out, and reported.
  Future<List<ChatGroup>> groups() async {
    final list = <ChatGroup>[];
    for (final id in await _loadGroupIndex()) {
      if (await _tryLoadGroup(id) case final group?) list.add(group);
    }
    return list;
  }

  /// The number of incoming messages in [list] not yet read.
  static int _unreadIn(Iterable<ChatMessage> list) =>
      list.where((m) => !m.outgoing && !m.read).length;

  /// The messages with [contactId], oldest first.
  /// When [limit] is provided, returns at most [limit] messages ending at [offset]
  /// messages before the newest message.
  Future<List<ChatMessage>> messages(
    String contactId, {
    int? limit,
    int? offset,
  }) async {
    final all = await _loadContact(contactId);
    if (limit == null || limit <= 0) {
      return List.unmodifiable(all);
    }
    final skipFromEnd = offset ?? 0;
    final endIndex = all.length - skipFromEnd;
    if (endIndex <= 0) return const [];
    final startIndex = endIndex > limit ? endIndex - limit : 0;
    return List.unmodifiable(all.sublist(startIndex, endIndex));
  }

  /// The total number of stored messages for [contactId].
  Future<int> messageCount(String contactId) async =>
      (await _loadContact(contactId)).length;

  /// The chats that have messages, by contact ID.
  Future<List<String>> contactIds() async => (await _loadIndex()).toList();

  Future<ChatMessage?> find(String contactId, String id) async {
    for (final message in await _loadContact(contactId)) {
      if (message.id == id) return message;
    }
    return null;
  }

  Future<bool> contains(String contactId, String id) async =>
      (await find(contactId, id)) != null;

  /// Stores [message] and returns it as stored. A message already stored (same
  /// id) is not added twice; the stored one is returned.
  ///
  /// A quote of a message in the same chat takes that message's text as it is
  /// stored when this write runs (see [_withQuoteOf]). The read and the write
  /// are one step, as in [changeMessage], so a reply written while its message
  /// is edited or deleted never keeps the text the message had before.
  Future<ChatMessage> add(ChatMessage message) async =>
      (await _storeOnce(message)).message;

  /// Like [add], but returns null when a message with the same id is already
  /// stored, so the caller can tell a message it has just kept from one it had.
  Future<ChatMessage?> addNew(ChatMessage message) async {
    final result = await _storeOnce(message);
    return result.added ? result.message : null;
  }

  Future<({ChatMessage message, bool added})> _storeOnce(
    ChatMessage message,
  ) => _inOrder(() async {
    // A group message filed under a group that is not saved would be kept as a
    // contact's chat, so it is refused.
    if (message.groupId != null && !await _isGroup(message.contactId)) {
      throw StateError('the group is not saved');
    }
    final list = [...await _loadContact(message.contactId)];
    final index = list.indexWhere((m) => m.id == message.id);
    if (index >= 0) return (message: list[index], added: false);
    final stored = _withQuoteOf(list, message);
    list.add(stored);
    await _saveContact(message.contactId, list);
    return (message: stored, added: true);
  });

  /// [message] with its quote given the text of the message it quotes in
  /// [list], as that message is stored now: empty once it is deleted for
  /// everyone. A quote of a message that is not in [list] keeps the text it
  /// came with.
  static ChatMessage _withQuoteOf(List<ChatMessage> list, ChatMessage message) {
    final quote = message.replyTo;
    if (quote == null) return message;
    final index = list.indexWhere((m) => m.id == quote.id);
    if (index < 0) return message;
    final target = list[index];
    final text = target.deletedForAll ? '' : ChatFrames.quoteText(target.text);
    return message.copyWith(replyTo: (id: quote.id, text: text));
  }

  /// Updates an existing message in-place. The stored star and times win over
  /// [message]'s: a caller often copies the message before an await, and a
  /// star or a time set meanwhile must not be written back over.
  Future<void> updateMessage(ChatMessage message) => _inOrder(() async {
    final list = [...await _loadContact(message.contactId)];
    final index = list.indexWhere((m) => m.id == message.id);
    if (index < 0) return;
    final stored = list[index];
    list[index] = message.copyWith(
      starred: stored.starred,
      deliveredAt: stored.deliveredAt,
      readAt: stored.readAt,
    );
    await _saveContact(message.contactId, list);
  });

  /// Sets the state of message [id]. In a group, [memberId] names the member
  /// the state is for, and only that member's state in [ChatMessage.memberStates]
  /// changes; the message's own state is then left as it is. [reason] goes with
  /// the message's own state only.
  Future<void> setState(
    String contactId,
    String id,
    ChatState state, {
    String? reason,
    String? memberId,
  }) => _inOrder(() async {
    final list = [...await _loadContact(contactId)];
    final index = list.indexWhere((m) => m.id == id);
    if (index < 0) return;
    // A message deleted for everyone is final: it is never sent, queued or
    // counted as not sent again, whatever state it had when it was deleted.
    if (list[index].deletedForAll && _isUnsent(state)) return;
    assert(memberId == null || list[index].groupId != null);
    list[index] = memberId == null
        ? list[index].withState(state, reason: reason)
        : list[index].withMemberState(memberId, state);
    await _saveContact(contactId, list);
  });

  static bool _isUnsent(ChatState state) =>
      state == ChatState.sending ||
      state == ChatState.queued ||
      state == ChatState.notSent;

  /// Marks the outgoing message [id] as being sent, and returns it as stored
  /// now. Returns null when it is gone or deleted for everyone, and then
  /// nothing is written. A caller sends the copy returned, never an older one,
  /// so a message deleted before this write is not sent with its text.
  Future<ChatMessage?> markSending(String contactId, String id) =>
      _inOrder(() async {
        final list = [...await _loadContact(contactId)];
        final index = list.indexWhere((m) => m.id == id);
        if (index < 0 || list[index].deletedForAll) return null;
        list[index] = list[index].withState(ChatState.sending);
        await _saveContact(contactId, list);
        return list[index];
      });

  /// The message [id] as stored when this read runs, or null when it is gone
  /// or deleted for everyone. It is read in the same order as [markSending],
  /// so a delete written before the read is always seen.
  Future<ChatMessage?> findUndeleted(String contactId, String id) =>
      _inOrder(() async {
        final message = await find(contactId, id);
        return message == null || message.deletedForAll ? null : message;
      });

  /// Sets the state of message [id] to [state] and records when it happened,
  /// in one write: [ChatState.delivered] sets [ChatMessage.deliveredAt] and
  /// [ChatState.read] sets [ChatMessage.readAt], each only the first time.
  /// [at] is in milliseconds since the epoch. For a one-to-one chat only: a
  /// group's members are acknowledged one by one with [setState].
  Future<void> setStateAt(
    String contactId,
    String id,
    ChatState state, {
    required int at,
  }) {
    assert(state == ChatState.delivered || state == ChatState.read);
    return _inOrder(() async {
      assert(!await _isGroup(contactId), 'a group uses setState');
      final list = [...await _loadContact(contactId)];
      final index = list.indexWhere((m) => m.id == id);
      if (index < 0) return;
      final message = list[index].withState(state);
      list[index] = state == ChatState.read
          ? message.copyWith(readAt: list[index].readAt ?? at)
          : message.copyWith(deliveredAt: list[index].deliveredAt ?? at);
      await _saveContact(contactId, list);
    });
  }

  /// Changes the message [id] in the chat with [contactId]. [change] gets the
  /// stored message and returns its replacement, or null to leave it as it is.
  /// The read and the write happen in one step, so a change made meanwhile is
  /// never lost. Returns whether the message was changed.
  ///
  /// A message that comes out deleted for everyone also takes its text out of
  /// the chat's quotes. A message whose text is edited gives its quotes the new
  /// text (see [_setQuotes]), so no quote keeps the text it had before.
  Future<bool> changeMessage(
    String contactId,
    String id,
    ChatMessage? Function(ChatMessage current) change,
  ) => _inOrder(() async {
    final list = [...await _loadContact(contactId)];
    final index = list.indexWhere((m) => m.id == id);
    if (index < 0) return false;
    final before = list[index];
    final next = change(before);
    if (next == null) return false;
    list[index] = next;
    if (next.deletedForAll) {
      // The deleted message keeps no quote of its own.
      list[index] = next.copyWith(clearReplyTo: true);
      _setQuotes(list, id, '');
    } else if (next.text != before.text) {
      _setQuotes(list, id, ChatFrames.quoteText(next.text));
    }
    await _saveContact(contactId, list);
    return true;
  });

  /// Gives each quote of the message [id] in [list] the text [quote]: empty
  /// once the message is deleted for everyone, its new text once it is edited.
  /// The quote keeps its id either way.
  static void _setQuotes(List<ChatMessage> list, String id, String quote) {
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      if (m.replyTo?.id == id) {
        list[i] = m.copyWith(replyTo: (id: id, text: quote));
      }
    }
  }

  /// The key of the pending controls for [contactId], or for a group member
  /// when [memberId] is given.
  static String _pendingKeyOf(String contactId, String? memberId) =>
      memberId == null
      ? pendingKey(contactId)
      : groupPendingKey(contactId, memberId);

  /// The pending reactions, edits and deletes for the contact, oldest first.
  /// For a group, [memberId] names the member the controls wait for, and
  /// controls older than [controlLifetime] by their own ts are left out.
  Future<List<ControlFrame>> pendingControls(
    String contactId, {
    String? memberId,
    DateTime Function()? clock,
  }) => _inOrder(() async {
    final list = await _loadPendingAt(_pendingKeyOf(contactId, memberId));
    final controls = [
      for (final frame in list)
        if (frame is ControlFrame) frame,
    ];
    if (memberId == null) return controls;
    final nowMs = (clock ?? DateTime.now)().millisecondsSinceEpoch;
    return [
      for (final control in controls)
        if (_isLive(control, nowMs)) control,
    ];
  });

  /// The group answers and leaves that [memberId] of the group [groupId] has
  /// not been sent yet, oldest first, left out once they are older than
  /// [controlLifetime] by their own ts.
  Future<List<GroupStateFrame>> pendingGroupStates(
    String groupId, {
    required String memberId,
    DateTime Function()? clock,
  }) => _inOrder(() async {
    final list = await _loadPendingAt(groupPendingKey(groupId, memberId));
    final nowMs = (clock ?? DateTime.now)().millisecondsSinceEpoch;
    return [
      for (final frame in list)
        if (frame is GroupStateFrame && _isLive(frame, nowMs)) frame,
    ];
  });

  /// Keeps [frame], a group answer or leave, until [memberId] of the group
  /// [groupId] can be sent it. The same frame is kept once. Like a control for
  /// a member, it is dropped past its lifetime, and the oldest goes past
  /// [maxPendingControls].
  Future<void> queueGroupState(
    String groupId,
    String memberId,
    GroupStateFrame frame, {
    DateTime Function()? clock,
  }) => _inOrder(() async {
    final nowMs = (clock ?? DateTime.now)().millisecondsSinceEpoch;
    if (!_isLive(frame, nowMs)) return;
    final key = groupPendingKey(groupId, memberId);
    final encoded = ChatFrames.encode(frame);
    final list = [
      for (final older in await _loadPendingAt(key))
        if (_isLive(older, nowMs) && ChatFrames.encode(older) != encoded) older,
      frame,
    ];
    while (list.length > maxPendingControls) {
      list.removeAt(0);
    }
    await _savePendingAt(key, list);
  });

  /// Whether [frame] is still within its lifetime at [nowMs] (see
  /// [controlLifetime]), measured from its own ts.
  static bool _isLive(ChatFrame frame, int nowMs) =>
      nowMs - _frameTs(frame) <= controlLifetime.inMilliseconds;

  static int _frameTs(ChatFrame frame) => switch (frame) {
    ReactFrame(:final ts) => ts,
    EditFrame(:final ts) => ts,
    DeleteFrame(:final ts) => ts,
    GroupStateFrame(:final ts) => ts,
    _ => throw StateError('not a pending frame'),
  };

  /// Keeps [control] until the chat with [contactId] can carry it (see
  /// `docs/PROTOCOL.md` §5.10). A control replaces the older one of its kind
  /// on the same message: a reaction replaces a reaction, an edit replaces an
  /// edit, and a delete replaces both. So a message can have one pending
  /// reaction and one pending edit at once, never two of the same kind. Past
  /// [maxPendingControls], the oldest is dropped.
  ///
  /// For a group, [memberId] names the member the control waits for, and the
  /// controls of that member that are older than [controlLifetime] by their
  /// own ts are dropped here too (the clock is [clock], or this device's).
  Future<void> queueControl(
    String contactId,
    ControlFrame control, {
    String? memberId,
    DateTime Function()? clock,
  }) => _inOrder(() async {
    final key = _pendingKeyOf(contactId, memberId);
    final list = [...await _loadPendingAt(key)];
    list.removeWhere((older) => _supersedes(control, older));
    if (memberId != null) {
      final nowMs = (clock ?? DateTime.now)().millisecondsSinceEpoch;
      if (!_isLive(control, nowMs)) return;
      list.removeWhere((older) => !_isLive(older, nowMs));
    }
    list.add(control);
    while (list.length > maxPendingControls) {
      list.removeAt(0);
    }
    await _savePendingAt(key, list);
  });

  /// Takes [control] off the pending list, once it has been sent. Only the
  /// same control is removed, so one queued meanwhile is kept.
  Future<void> removeControl(
    String contactId,
    ChatFrame control, {
    String? memberId,
  }) => _inOrder(() async {
    final key = _pendingKeyOf(contactId, memberId);
    final sent = ChatFrames.encode(control);
    final list = [...await _loadPendingAt(key)];
    final before = list.length;
    list.removeWhere((c) => ChatFrames.encode(c) == sent);
    if (list.length != before) await _savePendingAt(key, list);
  });

  /// Whether [newer] replaces [older] in the pending list.
  static bool _supersedes(ControlFrame newer, ChatFrame older) {
    if (older is! ControlFrame || newer.id != older.id) return false;
    return switch (newer) {
      DeleteFrame() => true,
      ReactFrame() => older is ReactFrame,
      EditFrame() => older is EditFrame,
    };
  }

  /// The frames kept under [key]: controls, and group answers and leaves.
  Future<List<ChatFrame>> _loadPendingAt(String key) async {
    await _checkMigration();
    final raw = await _store.read(key);
    if (raw == null) return [];
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! List) throw const ChatStoreException('unreadable');
    final frames = <ChatFrame>[];
    for (final item in json) {
      if (item is! String) throw const ChatStoreException('unreadable');
      try {
        final frame = ChatFrames.decode(item);
        if (frame is! ControlFrame && frame is! GroupStateFrame) {
          throw const ChatFrameException('unknown');
        }
        frames.add(frame);
      } on ChatFrameException {
        throw const ChatStoreException('unreadable');
      }
    }
    return frames;
  }

  Future<void> _savePendingAt(String key, List<ChatFrame> list) async {
    if (list.isEmpty) {
      await _store.delete(key);
      return;
    }
    await _store.write(
      key,
      jsonEncode([for (final c in list) ChatFrames.encode(c)]),
    );
  }

  /// The invites of the group [groupId] that are not answered yet, in the
  /// order they were queued.
  Future<List<PendingInvite>> pendingInvites(String groupId) =>
      _inOrder(() => _loadInvites(groupId));

  /// Keeps [invite] until its invitee answers or it expires. An invite to the
  /// same invitee replaces the one kept.
  Future<void> queueInvite(PendingInvite invite) => _inOrder(() async {
    final list = [
      for (final older in await _loadInvites(invite.group))
        if (older.invitee != invite.invitee) older,
      invite,
    ];
    await _saveInvites(invite.group, list);
  });

  /// Takes the invite to [invitee] off the pending list, once it is answered.
  Future<void> removeInvite(String groupId, String invitee) =>
      _inOrder(() async {
        final list = await _loadInvites(groupId);
        final kept = [
          for (final invite in list)
            if (invite.invitee != invitee) invite,
        ];
        if (kept.length != list.length) await _saveInvites(groupId, kept);
      });

  Future<List<PendingInvite>> _loadInvites(String groupId) async {
    final raw = await _store.read(groupInvitesKey(groupId));
    if (raw == null) return [];
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! List) throw const ChatStoreException('unreadable');
    final invites = <PendingInvite>[];
    for (final item in json) {
      final invite = PendingInvite.fromJson(groupId, item);
      if (invite == null) throw const ChatStoreException('unreadable');
      invites.add(invite);
    }
    return invites;
  }

  Future<void> _saveInvites(String groupId, List<PendingInvite> list) async {
    if (list.isEmpty) {
      await _store.delete(groupInvitesKey(groupId));
      return;
    }
    await _store.write(
      groupInvitesKey(groupId),
      jsonEncode([for (final invite in list) invite.toJson()]),
    );
  }

  /// Deletes the whole chat with [contactId].
  Future<void> deleteChat(String contactId) async {
    final removed = await _inOrder(() async {
      await _checkMigration();
      if (await _isGroup(contactId)) return _deleteGroup(contactId);
      final messages = [...await _loadContact(contactId)];
      final index = await _loadIndex();
      final next = {...index}..remove(contactId);
      final indexChanged = next.length != index.length;
      await _store.writeAll(
        {if (indexChanged) contactsIndexKey: jsonEncode(next.toList())},
        deleted: [
          summaryKey(contactId),
          pendingKey(contactId),
          contactKey(contactId),
          metaKey(contactId),
          '$retentionPrefix$contactId',
        ],
      );
      _cachedChats.remove(contactId);
      _cachedMeta.remove(contactId);
      if (indexChanged) _contactIndex = next;
      if (!_changes.isClosed) {
        _changes.add(null);
      }
      return messages;
    });
    await _discardFiles(removed);
  }

  /// Deletes the group [groupId] with its record, messages, summary, settings
  /// and retention, in one write. Called inside [_inOrder]. Returns its
  /// messages, whose files the caller deletes.
  Future<List<ChatMessage>> _deleteGroup(String groupId) async {
    final messages = [...await _loadContact(groupId)];
    final record = await _loadGroup(groupId);
    final index = await _loadGroupIndex();
    final next = {...index}..remove(groupId);
    await _store.writeAll(
      {
        if (next.length != index.length)
          groupsIndexKey: jsonEncode(next.toList()),
      },
      deleted: [
        groupKey(groupId),
        groupMessagesKey(groupId),
        groupSummaryKey(groupId),
        groupInvitesKey(groupId),
        metaKey(groupId),
        '$retentionPrefix$groupId',
        for (final member in record?.members ?? const <GroupMember>[])
          groupPendingKey(groupId, member.id),
      ],
    );
    _cachedGroups.remove(groupId);
    _cachedChats.remove(groupId);
    _cachedMeta.remove(groupId);
    if (next.length != index.length) _groupIndex = next;
    if (!_changes.isClosed) {
      _changes.add(null);
    }
    return messages;
  }

  /// Deletes the files that [messages] received. Done after the chat records
  /// are gone, so a file is never left behind by a message that is no longer
  /// stored.
  Future<void> _discardFiles(Iterable<ChatMessage> messages) async {
    for (final message in messages) {
      await files?.remove(message.filePath);
      _drop(_voiceKey(message.id));
      _drop(_fileKey(message.fileId ?? message.id));
      _drop(_fileKey(message.id));
    }
  }

  /// The decrypted bytes of a received file. Throws [ReceivedFileException]
  /// when the file is not on this device or cannot be opened.
  Future<Uint8List> readFile(ChatMessage message) async {
    final store = files;
    final name = message.filePath;
    final key = message.fileKey;
    final fileId = message.fileId ?? message.id;
    if (store == null || name == null || key == null) {
      final held =
          _held(_fileKey(fileId)) ??
          _held(_fileKey(message.id)) ??
          _held(_voiceKey(message.id));
      if (held != null) return held;
      throw const ReceivedFileException('missing');
    }
    return store.read(name: name, key: key);
  }

  /// Whether the bytes of a file are still here: in the file
  /// store, or held by the browser for this tab.
  bool hasFile(ChatMessage message) {
    final fileId = message.fileId ?? message.id;
    return _browserHeld.containsKey(_fileKey(fileId)) ||
        _browserHeld.containsKey(_fileKey(message.id)) ||
        _browserHeld.containsKey(_voiceKey(message.id)) ||
        (files != null && message.filePath != null && message.fileKey != null);
  }

  /// Whether the bytes of a voice note are still here to play: in the file
  /// store, or held by the browser for this tab.
  bool hasVoice(ChatMessage message) =>
      _browserHeld.containsKey(_voiceKey(message.id)) ||
      (files != null && message.filePath != null && message.fileKey != null);

  /// Keeps the bytes of a voice note the sender offered, so its own bubble
  /// can play it. Native: an encrypted file, like a received one. Browser:
  /// memory for this tab. Returns the message with its file recorded.
  Future<ChatMessage> keepVoice(ChatMessage message, Uint8List bytes) async {
    final store = files;
    if (store == null) {
      rememberVoice(message.id, bytes);
      return message;
    }
    try {
      final kept = await store.save(bytes);
      final updated = message.copyWith(filePath: kept.name, fileKey: kept.key);
      await updateMessage(updated);
      return updated;
    } catch (_) {
      // The offer still goes; only the sender's own playback is lost.
      return message;
    }
  }

  /// Keeps a voice note the browser received, for this tab (see [readFile]).
  void rememberVoice(String id, Uint8List bytes) {
    _hold(_voiceKey(id), bytes);
  }

  /// Drops a voice note the browser held, when its message is gone.
  void forgetVoice(String id) {
    _drop(_voiceKey(id));
  }

  /// Keeps a file attachment the browser sent or received, for this tab.
  /// Within [browserMemoryBytes]: older files may be let go.
  void rememberFile(String id, Uint8List bytes) {
    _hold(_fileKey(id), bytes);
  }

  /// Drops a file attachment the browser held, when its message is gone.
  void forgetFile(String id) {
    _drop(_fileKey(id));
  }

  /// Keeps the bytes of a file this device sends, so it can be sent when the
  /// contact accepts it (and shown here). Native: an encrypted file. Browser:
  /// memory for this tab (a voice note as one, any other file as a file),
  /// with a `web:` path. Returns [message] with where the file is kept; the
  /// message itself is not stored here.
  Future<ChatMessage> keepOutgoingFile(
    ChatMessage message,
    Uint8List bytes,
  ) async {
    final store = files;
    final id = message.fileId ?? message.id;
    if (store == null) {
      if (message.voiceNote) {
        rememberVoice(message.id, bytes);
      } else {
        rememberFile(id, bytes);
      }
      return message.copyWith(filePath: 'web:$id');
    }
    final kept = await store.save(bytes);
    return message.copyWith(filePath: kept.name, fileKey: kept.key);
  }

  /// A decrypted copy of a received file, for another app to open. The copy
  /// is plaintext in the temporary folder until the app next starts.
  Future<File> openCopy(ChatMessage message) async {
    final store = files;
    if (store == null) throw const ReceivedFileException('missing');
    final bytes = await readFile(message);
    return store.writeOpenCopy(message.fileName ?? 'file', bytes);
  }

  /// Moves received files that earlier versions kept as plaintext into the
  /// encrypted store. A file that cannot be moved is left as it is and opens
  /// as unavailable.
  Future<void> encryptLegacyFiles() async {
    final store = files;
    if (store == null) return;
    for (final contactId in await contactIds()) {
      final list = await _tryLoad(contactId) ?? const <ChatMessage>[];
      for (final message in list) {
        final path = message.filePath;
        if (path == null ||
            message.fileKey != null ||
            path.startsWith('web:')) {
          continue;
        }
        try {
          final sealed = await store.save(await File(path).readAsBytes());
          await updateMessage(
            message.copyWith(filePath: sealed.name, fileKey: sealed.key),
          );
          await store.remove(path);
        } catch (_) {}
      }
    }
  }

  /// Drops a chat that has no messages left. Its pin goes with it: an empty
  /// chat is not counted toward the pin limit, so a pin kept here would let
  /// the chat come back pinned past it. Its archived and muted settings stay.
  Future<void> _forgetEmptyChat(String contactId) async {
    // A group stays listed while it exists, so it keeps its pin.
    if (await _isGroup(contactId)) {
      await _saveGroupMessages(contactId, const []);
      return;
    }
    final index = await _loadIndex();
    final next = {...index}..remove(contactId);
    final indexChanged = next.length != index.length;
    final meta = (await _metaOf(contactId)).copyWith(clearPinnedAt: true);
    await _store.writeAll(
      {
        if (indexChanged) contactsIndexKey: jsonEncode(next.toList()),
        if (!meta.isDefault) metaKey(contactId): jsonEncode(meta.toJson()),
      },
      deleted: [
        summaryKey(contactId),
        contactKey(contactId),
        if (meta.isDefault) metaKey(contactId),
      ],
    );
    _cachedChats[contactId] = [];
    _cachedMeta[contactId] = meta;
    if (indexChanged) _contactIndex = next;
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  /// Deletes a single message with [id] in the chat with [contactId].
  Future<void> deleteMessage(String contactId, String id) async {
    final removed = await _inOrder(() async {
      final list = [...await _loadContact(contactId)];
      final index = list.indexWhere((m) => m.id == id);
      if (index < 0) return null;
      final message = list.removeAt(index);
      if (list.isEmpty) {
        await _forgetEmptyChat(contactId);
      } else {
        await _saveContact(contactId, list);
      }
      return message;
    });
    if (removed != null) await _discardFiles([removed]);
  }

  static const retentionPrefix = 'sotto.chats.retention.';

  /// Marks all incoming messages from [contactId] as read. Returns the ids
  /// of messages that were newly marked as read.
  Future<List<String>> markAsRead(String contactId) => _inOrder(() async {
    final list = [...await _loadContact(contactId)];
    final readIds = <String>[];
    var changed = false;
    for (var i = 0; i < list.length; i++) {
      final message = list[i];
      if (!message.outgoing && !message.read) {
        list[i] = message.copyWith(read: true);
        readIds.add(message.id);
        changed = true;
      }
    }
    if (changed) {
      await _saveContact(contactId, list);
    }
    return readIds;
  });

  /// The disappearing message duration for [contactId]. Duration.zero means off.
  Future<Duration> retention(String contactId) async {
    final raw = await _store.read('$retentionPrefix$contactId');
    if (raw == null) return Duration.zero;
    final seconds = int.tryParse(raw);
    return seconds == null || seconds <= 0
        ? Duration.zero
        : Duration(seconds: seconds);
  }

  /// Sets the disappearing message duration for [contactId]. Duration.zero turns it off.
  Future<void> setRetention(
    String contactId,
    Duration duration, {
    DateTime Function()? clock,
  }) => _inOrder(() async {
    if (duration <= Duration.zero) {
      await _store.delete('$retentionPrefix$contactId');
    } else {
      await _store.write('$retentionPrefix$contactId', '${duration.inSeconds}');
    }
    final result = await _sweepInternal(contactId: contactId, clock: clock);
    // The files go once the records are gone (see _discardFiles).
    return result.removed;
  }).then((removed) => _discardFiles(removed));

  /// Sweeps expired messages across all chats (or only [contactId]).
  /// Returns the number of purged messages.
  Future<int> sweepExpired({
    String? contactId,
    DateTime Function()? clock,
  }) async {
    final result = await _inOrder(
      () => _sweepInternal(contactId: contactId, clock: clock),
    );
    await _discardFiles(result.removed);
    return result.count;
  }

  /// Removes the messages that have expired, and returns how many there were
  /// and which ones (their files are deleted by the caller).
  Future<({int count, List<ChatMessage> removed})> _sweepInternal({
    String? contactId,
    DateTime Function()? clock,
  }) async {
    final nowMs = (clock ?? DateTime.now)().millisecondsSinceEpoch;
    final targetIds = contactId != null
        ? [contactId]
        : [...await _loadIndex(), ...await _loadGroupIndex()];
    final removed = <ChatMessage>[];
    for (final id in targetIds) {
      final dur = await retention(id);
      if (dur <= Duration.zero) continue;
      final maxAgeMs = dur.inMilliseconds;
      final List<ChatMessage> list;
      try {
        list = [...await _loadContact(id)];
      } on ChatStoreException {
        continue;
      }
      final expired = list
          .where((m) => (nowMs - m.clockMs) > maxAgeMs)
          .toList();
      if (expired.isEmpty) continue;
      removed.addAll(expired);
      list.removeWhere((m) => (nowMs - m.clockMs) > maxAgeMs);
      if (list.isEmpty) {
        await _forgetEmptyChat(id);
      } else {
        await _saveContact(id, list);
      }
    }
    return (count: removed.length, removed: removed);
  }

  /// The messages of [contactId], or null when that chat cannot be read. Lists
  /// over all chats skip such a chat, so one unreadable chat does not stop the
  /// Chats tab or the unread badge (the chat itself still reports the problem).
  Future<List<ChatMessage>?> _tryLoad(String contactId) async {
    try {
      return await _loadContact(contactId);
    } on ChatStoreException {
      return null;
    }
  }

  /// The summary of the chat with [contactId]: its last message as stored and
  /// its unread count. Null when the chat has no messages.
  ///
  /// A chat with no summary record (one from an earlier vault) is rebuilt from
  /// its messages once, and the record is written. A summary that shows
  /// settings is kept only while they match the settings record (the record
  /// is the authority, see [_metaOf]); otherwise it is rebuilt the same way.
  /// A record that is not a summary throws [ChatStoreException], and is not
  /// overwritten here.
  Future<ChatThreadSummary?> threadSummary(String contactId) async {
    final group = await _isGroup(contactId);
    final key = group ? groupSummaryKey(contactId) : summaryKey(contactId);
    final raw = await _store.read(key);
    if (raw != null) {
      final summary = _readSummary(contactId, raw, group: group);
      if (summary != null &&
          (summary.meta.isDefault || _cachedMeta[contactId] == summary.meta)) {
        return summary;
      }
    }
    return _inOrder<ChatThreadSummary?>(() async {
      // A change that ran first may have written the record meanwhile.
      final again = await _store.read(key);
      if (again != null) {
        final summary = _readSummary(contactId, again, group: group);
        if (summary != null && summary.meta == await _metaOf(contactId)) {
          return summary;
        }
      }
      final list = await _loadContact(contactId);
      if (list.isEmpty) return null;
      final meta = await _metaOf(contactId);
      try {
        await _store.write(key, _summaryJson(list, meta));
      } catch (_) {
        // The chat is listed from its messages all the same, and the record
        // is written again the next time it is read.
        _report(contactId, 'chat summary cannot be saved');
      }
      return ChatThreadSummary(
        contactId: contactId,
        groupId: group ? contactId : null,
        lastMessage: list.last,
        unreadCount: _unreadIn(list),
        meta: meta,
      );
    });
  }

  /// The summary held in [raw] for [contactId], a group's when [group]. Null
  /// when only its settings cannot be read: the caller rebuilds the record
  /// (see [threadSummary]). Throws [ChatStoreException] when [raw] is not a
  /// summary, and reports it, since nothing else shows it: the chat's messages
  /// still read fine.
  ChatThreadSummary? _readSummary(
    String contactId,
    String raw, {
    required bool group,
  }) {
    try {
      final summary = _summaryFrom(contactId, raw, group: group);
      if (summary == null) {
        _report(contactId, 'chat summary settings cannot be read');
      }
      return summary;
    } on ChatStoreException {
      _report(contactId, 'chat summary cannot be read');
      rethrow;
    }
  }

  /// The summary held in [raw] for [contactId]. Null when its settings cannot
  /// be read. Throws [ChatStoreException] when [raw] is not a summary.
  static ChatThreadSummary? _summaryFrom(
    String contactId,
    String raw, {
    required bool group,
  }) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      throw const ChatStoreException('unreadable');
    }
    if (json is! Map<String, dynamic>) {
      throw const ChatStoreException('unreadable');
    }
    final last = json['last'];
    final unread = json['unread'];
    if (last is! Map<String, dynamic> || unread is! int || unread < 0) {
      throw const ChatStoreException('unreadable');
    }
    final meta = _settingsIn(json);
    if (meta == null) return null;
    final lastMessage = ChatMessage.fromJson(contactId, last);
    if (group && lastMessage.groupId != contactId) {
      throw const ChatStoreException('unreadable');
    }
    return ChatThreadSummary(
      contactId: contactId,
      groupId: group ? contactId : null,
      lastMessage: lastMessage,
      unreadCount: unread,
      meta: meta,
    );
  }

  /// The settings a summary record holds. A record from before the settings
  /// were kept has none: the defaults. Null when they have the wrong type.
  static ChatMeta? _settingsIn(Map<String, dynamic> json) {
    final metaRaw = json['meta'];
    return metaRaw == null ? ChatMeta.defaults : ChatMeta.fromJson(metaRaw);
  }

  /// [threadSummary], or null when the chat's record cannot be read. Lists over
  /// all chats skip such a chat, as [_tryLoad] does.
  Future<ChatThreadSummary?> _tryLoadSummary(String contactId) async {
    try {
      return await threadSummary(contactId);
    } on ChatStoreException {
      return null;
    }
  }

  /// The number of unread incoming messages across all chats, groups
  /// included. Reads the summary records, not the messages.
  Future<int> totalUnreadCount() async {
    final ids = [...await _loadIndex(), ...await _loadGroupIndex()];
    var count = 0;
    for (final id in ids) {
      count += (await _tryLoadSummary(id))?.unreadCount ?? 0;
    }
    return count;
  }

  /// The number of unread incoming messages with [contactId]. Reads the
  /// summary record, not the messages: the contacts list asks for it on every
  /// change.
  Future<int> unreadCount(String contactId) async =>
      (await _tryLoadSummary(contactId))?.unreadCount ?? 0;

  /// The chats for the main list: the chats with messages that are not
  /// archived, pinned ones first (see [_mainOrder]), then newest first. Reads
  /// the summary records, not the messages.
  Future<List<ChatThreadSummary>> recentChats() async {
    final chats = await _summaries();
    return _mainOrder([
      for (final chat in chats)
        if (!chat.meta.archived) chat,
    ]);
  }

  /// The archived chats, newest first. Each keeps its unread count, which the
  /// Archived row shows. Reads the summary records, not the messages.
  Future<List<ChatThreadSummary>> archivedChats() async {
    final chats = await _summaries();
    return _newestFirst([
      for (final chat in chats)
        if (chat.meta.archived) chat,
    ]);
  }

  /// The summaries of the chats that can be read: the contacts' with messages,
  /// and every group. A chat that cannot be read is left out, as
  /// [_tryLoadSummary] does.
  Future<List<ChatThreadSummary>> _summaries() async {
    final summaries = <ChatThreadSummary>[];
    for (final id in await _loadIndex()) {
      if (await _tryLoadSummary(id) case final summary?) {
        summaries.add(summary);
      }
    }
    for (final id in await _loadGroupIndex()) {
      if (await _groupSummary(id) case final summary?) {
        summaries.add(summary);
      }
    }
    return summaries;
  }

  /// The summary of the group [groupId] for the list. A group with no messages
  /// has no summary record, so it is listed from its record and settings, with
  /// no last message. Null when the group or its messages cannot be read.
  Future<ChatThreadSummary?> _groupSummary(String groupId) async {
    if (await _tryLoadSummary(groupId) case final summary?) return summary;
    // Null here also when the summary cannot be read: only an empty group is
    // listed without one.
    final list = await _tryLoad(groupId);
    if (list == null || list.isNotEmpty) return null;
    final group = await _tryLoadGroup(groupId);
    if (group == null) return null;
    return ChatThreadSummary(
      contactId: groupId,
      groupId: groupId,
      groupCreatedMs: group.createdAt,
      unreadCount: 0,
      meta: await chatMeta(groupId),
    );
  }

  /// [chats] newest first, by the time each last changed (see
  /// [ChatThreadSummary.sortMs]).
  static List<ChatThreadSummary> _newestFirst(List<ChatThreadSummary> chats) =>
      [...chats]..sort((a, b) => b.sortMs.compareTo(a.sortMs));

  /// The order of the main list. Pinned chats come first, in the order they
  /// were pinned, at most [maxPinnedChats] of them. The rest keep their
  /// newest-first order, and so does any pinned chat past the limit.
  static List<ChatThreadSummary> _mainOrder(List<ChatThreadSummary> chats) {
    final newest = _newestFirst(chats);
    final pinned = [
      for (final chat in newest)
        if (chat.meta.pinnedAt != null) chat,
    ]..sort((a, b) => a.meta.pinnedAt!.compareTo(b.meta.pinnedAt!));
    final first = pinned.take(maxPinnedChats).toList();
    final firstIds = {for (final chat in first) chat.contactId};
    return [
      ...first,
      for (final chat in newest)
        if (!firstIds.contains(chat.contactId)) chat,
    ];
  }

  /// Searches all stored messages across all contacts matching [query].
  Future<List<ChatMessage>> searchAll(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final ids = [...await _loadIndex(), ...await _loadGroupIndex()];
    final results = <ChatMessage>[];
    for (final id in ids) {
      final list = await _tryLoad(id);
      if (list == null) continue;
      for (final msg in list) {
        if (msg.text.toLowerCase().contains(q) ||
            (msg.fileName?.toLowerCase().contains(q) ?? false)) {
          results.add(msg);
        }
      }
    }
    results.sort((a, b) => b.clockMs.compareTo(a.clockMs));
    return results;
  }
}

/// A brief overview of a chat conversation for recent chat listings.
class ChatThreadSummary {
  const ChatThreadSummary({
    required this.contactId,
    required this.unreadCount,
    this.lastMessage,
    this.groupId,
    this.groupCreatedMs,
    this.meta = ChatMeta.defaults,
  }) : assert(groupId == null || groupId == contactId);

  /// The chat's key: the contact's Sotto ID, or for a group the group's id
  /// (see [groupId]).
  final String contactId;

  /// The group's id for a group chat, or null for a one-to-one chat.
  final String? groupId;

  /// The last message as stored, or null for a group with no messages yet.
  final ChatMessage? lastMessage;

  /// When the group was made, for a group with no messages yet. Null otherwise.
  final int? groupCreatedMs;

  final int unreadCount;

  /// The chat's archived, muted and pinned settings.
  final ChatMeta meta;

  /// When the chat last changed on this device: the time of its last message,
  /// or when an empty group was made. The main list orders by it.
  int get sortMs => lastMessage?.clockMs ?? groupCreatedMs ?? 0;
}
