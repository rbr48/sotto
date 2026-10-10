import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart' show PlayerState;
import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../call/call_controller.dart';
import '../../contacts/contact_book.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/test_hooks.dart';
import '../../core/ui_kit.dart';
import '../chat_frames.dart';
import '../chat_manager.dart';
import '../chat_session.dart';
import '../chat_store.dart';
import '../file_storage.dart';
import '../voice/voice_format.dart';
import '../voice/voice_player.dart';
import '../voice/voice_recorder.dart';
import '../web_download.dart';
import 'chat_tokens.dart';
import 'emoji_picker_panel.dart';
import 'forward_picker.dart';
import 'message_info_sheet.dart';
import 'message_menu.dart';
import 'reaction_bar.dart';
import 'starred_page.dart';

/// Whether a day separator goes above a message: it is the first message
/// shown, or its local calendar day differs from the one before it.
///
/// Pure, so the rule can be tested with any clock.
bool needsDaySeparator({required int? previousClockMs, required int clockMs}) {
  if (previousClockMs == null) return true;
  return !DateUtils.isSameDay(
    DateTime.fromMillisecondsSinceEpoch(previousClockMs),
    DateTime.fromMillisecondsSinceEpoch(clockMs),
  );
}

/// The most files sent from one pick of the attach button.
const maxFilesPerPick = 10;

/// Offers each picked file in turn, the first [maxFilesPerPick] in the order
/// picked. A file that is refused (a blocked type, an unreadable image, one
/// that is too large) is skipped and the rest still go. Returns the skipped
/// files with the reason each was refused.
Future<List<({String name, Object error})>> sendPickedFiles({
  required List<
    ({String name, Future<Uint8List> Function() read, String? mime})
  >
  picked,
  required Future<Object?> Function(String name, Uint8List bytes, String mime)
  offer,
  Future<void> Function()? onSent,
}) async {
  final skipped = <({String name, Object error})>[];
  for (final file in picked.take(maxFilesPerPick)) {
    try {
      if (ChatFrames.isBlockedFileType(file.name) ||
          ChatFrames.isBlockedFileType(ChatFrames.cleanFileName(file.name))) {
        throw ArgumentError('Blocked file type: ${file.name}');
      }
      // No size check here: offerFile removes an image's metadata first, and
      // the limit applies to what is sent. It refuses a file over the limit.
      final bytes = await file.read();
      final mime = file.mime ?? 'application/octet-stream';
      await offer(file.name, bytes, mime);
      await onSent?.call();
    } catch (e) {
      skipped.add((name: file.name, error: e));
    }
  }
  return skipped;
}

/// The message to show when [ChatSession.offerFile] refuses a file. Its
/// refusals for a blocked type, the size limit and the two image errors are
/// translated. Any other error is shown as it is.
///
/// Pure, so the mapping can be tested in any language.
String offerErrorMessage(AppLocalizations l10n, Object error) {
  if (error is ArgumentError) {
    final message = error.message;
    if (message is String) {
      if (message.startsWith('Blocked file type')) return l10n.chatFileBlocked;
      if (message == 'File exceeds max size limit') {
        return l10n.chatFileTooLarge;
      }
      if (message == 'Image could not be read') return l10n.chatImageUnreadable;
      if (message == 'Image type not supported for sharing') {
        return l10n.chatImageUnsupported;
      }
    }
  }
  return '$error';
}

/// The text a failed open or save shows. A file that is gone or unreadable
/// has its own text. Anything else shows [fallback] alone: the exception's
/// text names internal types and paths, so it is not shown.
///
/// Pure, so the mapping can be tested in any language.
String fileErrorMessage(AppLocalizations l10n, Object error, String fallback) {
  return switch (error) {
    ReceivedFileException(reason: 'missing') => l10n.chatFileUnavailable,
    ReceivedFileException() => l10n.chatFileUnreadable,
    _ => fallback,
  };
}

/// The widest or tallest image a chat will decode, in pixels.
const maxImageSide = 8192;

/// The most pixels a chat will decode in one image (40 megapixels).
const maxImagePixels = 40000000;

/// The long side the full-screen viewer decodes an image to, at most.
const maxViewerSide = 4096;

/// Whether an image of [width] by [height] pixels may be decoded. A received
/// image is chosen by the peer, and a small file can declare a size that
/// takes gigabytes to decode, so anything larger is refused.
///
/// Pure, so the limits can be tested on their own.
bool imageSizeAllowed(int width, int height) =>
    width > 0 &&
    height > 0 &&
    width <= maxImageSide &&
    height <= maxImageSide &&
    width * height <= maxImagePixels;

/// The size an encoded image declares in its header, read without decoding
/// its pixels. Null when the bytes are not an image the engine can read.
Future<({int width, int height})?> imageHeaderSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (width: descriptor.width, height: descriptor.height);
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// The size of [bytes] when it is an image safe to decode, else null.
Future<({int width, int height})?> safeImageSize(Uint8List bytes) async {
  final size = await imageHeaderSize(bytes);
  if (size == null || !imageSizeAllowed(size.width, size.height)) return null;
  return size;
}

/// The text shown when Android refuses to open a received file, by the
/// error code its native side returns.
///
/// Pure, so the mapping can be tested in any language.
String openFileErrorMessage(AppLocalizations l10n, String code) =>
    switch (code) {
      'blocked_type' => l10n.chatFileTypeCannotOpen,
      'no_app' => l10n.chatFileNoApp,
      _ => l10n.chatFileOpenFailed,
    };

/// How a day separator names its day, judged from the current day.
enum ChatDayLabel { today, yesterday, other }

/// [day] and [now] are local times. The count of days between them is taken
/// on UTC dates made from their local fields, so a daylight-saving change
/// never moves a message into the wrong day.
ChatDayLabel chatDayLabel({required DateTime day, required DateTime now}) {
  final days = DateTime.utc(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime.utc(day.year, day.month, day.day)).inDays;
  return switch (days) {
    0 => ChatDayLabel.today,
    1 => ChatDayLabel.yesterday,
    _ => ChatDayLabel.other,
  };
}

/// One chat with a contact: the messages, a box to write in, and what
/// happened when the connection was made.
///
/// Messages go directly between the two devices, so the page says when a
/// message could not go, and offers to send it again.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.chat,
    required this.contactId,
    required this.name,
    this.sendTyping = true,
    this.sendReadReceipts = true,
    this.verified = false,
    this.calls,
    this.avatar,
    this.contacts,
    this.focusMessageId,
  });

  final String? avatar;

  /// A message to open the chat at, from the starred list. The chat opens at
  /// it only if the message is among those loaded; otherwise at the newest.
  final String? focusMessageId;

  final ChatManager chat;

  /// The contact's Sotto ID.
  final String contactId;

  /// The contact's name, for the title.
  final String name;

  /// Whether to emit real-time typing indicators.
  final bool sendTyping;

  /// Whether to send read receipts when viewing incoming messages.
  final bool sendReadReceipts;

  /// Whether you marked this contact as verified. A snapshot taken when the
  /// chat opens. The app runs no check of its own, so this is your own
  /// confirmation, and the badge says so.
  final bool verified;

  /// The call controller. A call that is active or ringing keeps the
  /// microphone, so voice messages cannot be recorded then. Null in tests.
  final CallController? calls;

  /// The contacts, to forward a message to one of them. Null: there is no one
  /// to forward to.
  final ContactBook? contacts;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  bool _showEmoji = false;

  /// The message a reply will answer, and the message being edited. Starting
  /// one ends the other.
  ChatMessage? _replyTo;
  ChatMessage? _editing;

  /// The message whose reaction choices are open, if any.
  String? _reactingId;

  /// One key per message, so a quote can find the message it quotes.
  final _itemKeys = <String, GlobalKey>{};

  StreamSubscription<ChatManagerEvent>? _events;
  List<ChatMessage> _messages = const [];

  static const int _pageSize = 50;
  int _loadedCount = _pageSize;
  bool _hasMore = true;
  bool _isLoadingMore = false;

  bool _isSearching = false;
  String _searchQuery = '';

  /// What went wrong with the last connection, shown until dismissed.
  String? _problem;
  bool _sending = false;
  Timer? _typingDebounceTimer;
  Timer? _peerTypingTimer;
  bool _peerIsTyping = false;
  bool _myTypingSent = false;
  Duration? _retention;

  /// Whether this chat's notifications are muted on this device.
  bool _muted = false;

  /// Whether the chat has been opened at [ChatPage.focusMessageId] already.
  bool _focused = false;

  /// The recorder, made on the first voice message.
  VoiceRecorder? _voice;

  /// A recording is running.
  bool _recording = false;

  /// The recording was stopped at its limit and waits to be sent or cancelled.
  VoiceNote? _heldNote;

  /// A recording is starting, stopping or being sent.
  bool _voiceBusy = false;

  /// Redraws the elapsed time while a recording runs.
  Timer? _voiceTicker;

  /// Counts the recordings this page has started or discarded. An operation
  /// that finishes after a discard finds the count changed and drops its
  /// result.
  int _voiceGeneration = 0;

  /// Redraws the day labels at the next local midnight, so a chat that stays
  /// open past midnight does not keep calling a day "Today".
  Timer? _midnightTimer;

  bool get _voiceActive => _recording || _heldNote != null;

  /// Whether a call is active or ringing.
  bool get _callActive => widget.calls?.call.active ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.calls?.addListener(_onCallChanged);
    widget.chat.viewing(widget.contactId);
    _events = widget.chat.events.listen(_onEvent);
    _input.addListener(_onInputChanged);
    _inputFocusNode.addListener(_onInputFocusChanged);
    _scrollController.addListener(_onScroll);
    unawaited(_markAndSendRead());
    unawaited(_sweepThenLoad());
    unawaited(_loadRetention());
    unawaited(_loadMuted());
    _armMidnight();
  }

  void _onInputFocusChanged() {
    if (_inputFocusNode.hasFocus && _showEmoji) {
      setState(() => _showEmoji = false);
    }
  }

  /// Schedules a redraw for the next local midnight, by the injected clock.
  void _armMidnight() {
    _midnightTimer?.cancel();
    final now = widget.chat.clock();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _midnightTimer = Timer(nextMidnight.difference(now), () {
      if (!mounted) return;
      setState(() {});
      _armMidnight();
    });
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.calls != widget.calls) {
      oldWidget.calls?.removeListener(_onCallChanged);
      widget.calls?.addListener(_onCallChanged);
    }
  }

  /// A recording stops when the app leaves the screen. It is never sent after
  /// that. On resume the day labels are drawn again, since the midnight timer
  /// may not have run while the app was away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(_discardVoice());
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {});
      _armMidnight();
    }
  }

  /// A call that starts ends any recording, and the mic button follows the
  /// call.
  void _onCallChanged() {
    if (_callActive && (_voiceActive || _voiceBusy)) {
      unawaited(_discardVoice());
    }
    if (mounted) setState(() {});
  }

  /// Expired messages are removed before the chat is shown, so a chat opened
  /// after a long time does not show them.
  Future<void> _sweepThenLoad() async {
    await widget.chat.sweepExpired();
    if (mounted) await _load(reset: true);
  }

  Future<void> _loadRetention() async {
    final ret = await widget.chat.store.retention(widget.contactId);
    if (mounted) setState(() => _retention = ret);
  }

  /// Reads whether the chat is muted. Only this page changes it, so it is read
  /// once, when the chat opens, and not with each load of the messages.
  Future<void> _loadMuted() async {
    final meta = await widget.chat.store.chatMeta(widget.contactId);
    if (mounted) setState(() => _muted = meta.muted);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoadingMore && _hasMore) {
        unawaited(_loadMore());
      }
    }
  }

  Future<void> _markAndSendRead() async {
    final readIds = await widget.chat.store.markAsRead(widget.contactId);
    if (widget.sendReadReceipts && readIds.isNotEmpty) {
      widget.chat.sendReadReceipts(widget.contactId, readIds);
    }
  }

  void _onInputChanged() {
    if (!widget.sendTyping) return;
    final hasText = _input.text.trim().isNotEmpty;
    if (hasText && !_myTypingSent) {
      _myTypingSent = true;
      widget.chat.sendTyping(widget.contactId, true);
    } else if (!hasText && _myTypingSent) {
      _myTypingSent = false;
      widget.chat.sendTyping(widget.contactId, false);
    }
    _typingDebounceTimer?.cancel();
    if (hasText) {
      _typingDebounceTimer = Timer(const Duration(seconds: 3), () {
        if (_myTypingSent) {
          _myTypingSent = false;
          widget.chat.sendTyping(widget.contactId, false);
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.calls?.removeListener(_onCallChanged);
    if (_myTypingSent) {
      _myTypingSent = false;
      widget.chat.sendTyping(widget.contactId, false);
    }
    _typingDebounceTimer?.cancel();
    _peerTypingTimer?.cancel();
    _voiceTicker?.cancel();
    _midnightTimer?.cancel();
    _voiceGeneration++;
    unawaited(_voice?.dispose());
    _input.removeListener(_onInputChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    widget.chat.viewing(null);
    unawaited(_events?.cancel());
    _input.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) _loadedCount = _pageSize;
    final total = await widget.chat.store.messageCount(widget.contactId);
    final messages = await widget.chat.store.messages(
      widget.contactId,
      limit: _loadedCount,
    );
    if (!mounted) return;
    // The browser tests count the quotes shown: a quote is kept out of the
    // accessibility tree, so they cannot read it from there.
    if (testHooks) {
      publishForTests(
        'quotes',
        '${messages.where((m) => m.replyTo != null && !m.deletedForAll).length}',
      );
    }
    setState(() {
      _messages = messages;
      _hasMore = total > _loadedCount;
    });
    final focus = widget.focusMessageId;
    if (!_focused && focus != null) {
      _focused = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpTo(focus);
      });
    }
    await _endReplyIfGone();
  }

  /// Keeps the reply preview to the message it answers, as it is stored now.
  /// A reply ends when that message is gone or deleted for everyone, since
  /// there is then no text to quote. Returns whether a reply ended.
  Future<bool> _endReplyIfGone() async {
    final reply = _replyTo;
    if (reply == null) return false;
    final target = await widget.chat.store.find(widget.contactId, reply.id);
    if (!mounted || _replyTo?.id != reply.id) return false;
    if (target == null || target.deletedForAll) {
      setState(() => _replyTo = null);
      return true;
    }
    setState(() => _replyTo = target);
    return false;
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    _isLoadingMore = true;
    _loadedCount += _pageSize;
    final total = await widget.chat.store.messageCount(widget.contactId);
    final messages = await widget.chat.store.messages(
      widget.contactId,
      limit: _loadedCount,
    );
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _hasMore = total > _loadedCount;
      _isLoadingMore = false;
    });
  }

  void _onEvent(ChatManagerEvent event) {
    switch (event) {
      case ChatUpdate(:final contact, :final event)
          when contact == widget.contactId:
        if (event is PeerTyping) {
          _peerTypingTimer?.cancel();
          if (event.typing) {
            setState(() => _peerIsTyping = true);
            _peerTypingTimer = Timer(const Duration(seconds: 4), () {
              if (mounted) setState(() => _peerIsTyping = false);
            });
          } else {
            setState(() => _peerIsTyping = false);
          }
          return;
        }
        unawaited(_markAndSendRead());
        // An ordinary end (bye, closed, idle) needs no explanation.
        if (event is SessionEnded && !_ordinaryEnd(event.reason)) {
          setState(() => _problem = event.reason);
        }
        unawaited(_load());
      case ChatOpenFailure(:final contact, :final reason)
          when contact == widget.contactId:
        setState(() => _problem = reason);
        unawaited(_load());
      default:
        break;
    }
  }

  static bool _ordinaryEnd(String reason) =>
      reason == 'bye' || reason == 'closed' || reason == 'idle';

  String _problemText(AppLocalizations l10n, String reason) => switch (reason) {
    'no-relay' => l10n.chatFailNoRelay,
    'not-contact' || 'declined' => l10n.chatFailDeclined,
    _ => l10n.chatFailConnection,
  };

  void _toggleEmojiPicker() {
    if (_showEmoji) {
      setState(() => _showEmoji = false);
      _inputFocusNode.requestFocus();
    } else {
      _inputFocusNode.unfocus();
      setState(() => _showEmoji = true);
    }
  }

  void _onEmojiSelected(String emoji) {
    final text = _input.text;
    final selection = _input.selection;
    final start = selection.start;
    final end = selection.end;
    if (selection.isValid && start >= 0) {
      final newText = text.replaceRange(start, end, emoji);
      final newPos = start + emoji.length;
      _input.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newPos),
      );
    } else {
      final newText = text + emoji;
      _input.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  void _onEmojiBackspace() {
    final text = _input.text;
    final selection = _input.selection;
    if (text.isEmpty) return;
    if (selection.isValid && selection.start > 0) {
      if (selection.start != selection.end) {
        final newText = text.replaceRange(selection.start, selection.end, '');
        _input.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: selection.start),
        );
      } else {
        final beforeChars = text.substring(0, selection.start).characters;
        if (beforeChars.isNotEmpty) {
          final dropped = beforeChars.skipLast(1).toString();
          final after = text.substring(selection.start);
          _input.value = TextEditingValue(
            text: dropped + after,
            selection: TextSelection.collapsed(offset: dropped.length),
          );
        }
      }
    } else {
      final chars = text.characters;
      final dropped = chars.skipLast(1).toString();
      _input.value = TextEditingValue(
        text: dropped,
        selection: TextSelection.collapsed(offset: dropped.length),
      );
    }
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty || _sending) return;
    if (_myTypingSent) {
      _myTypingSent = false;
      widget.chat.sendTyping(widget.contactId, false);
    }
    _typingDebounceTimer?.cancel();
    setState(() => _sending = true);
    try {
      if (_editing case final editing?) {
        final edited = await widget.chat.edit(
          widget.contactId,
          editing.id,
          text,
        );
        if (edited) _input.clear();
        if (mounted) setState(() => _editing = null);
        if (!edited && mounted) {
          _showSnack(AppLocalizations.of(context).chatEditTooLate);
        }
      } else {
        await widget.chat.sendText(
          widget.contactId,
          text,
          replyToId: _replyTo?.id,
        );
        _input.clear();
        if (mounted) setState(() => _replyTo = null);
      }
    } on ArgumentError {
      // Too long, not a contact any more, or the message replied to is gone.
      // The text stays in the box, and the reply ends when its message is gone.
      final replyEnded = await _endReplyIfGone();
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        _showSnack(replyEnded ? l10n.chatReplyGone : l10n.chatSendRefused);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    await _load();
  }

  /// Starts a voice message, if the microphone is free.
  Future<void> _startVoiceRecording() async {
    if (_voiceBusy || _voiceActive || _callActive) return;
    final generation = ++_voiceGeneration;
    final voice = _voice ??= VoiceRecorder(
      files: widget.chat.store.files,
      onLimit: () => unawaited(_onVoiceLimit()),
    );
    setState(() => _voiceBusy = true);
    try {
      await voice.start();
      if (!mounted || generation != _voiceGeneration || _callActive) {
        await voice.cancel();
        return;
      }
      setState(() => _recording = true);
      _voiceTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } on VoiceRecordException catch (e) {
      _showVoiceError(e.failure);
    } catch (_) {
      // No recorder on this platform, or one that failed in an unexpected way.
      _showVoiceError(VoiceFailure.unavailable);
    } finally {
      if (mounted) setState(() => _voiceBusy = false);
    }
  }

  /// Ends the recording and offers it, unless a call started meanwhile.
  Future<void> _sendVoice() async {
    if (_voiceBusy || !_voiceActive) return;
    final generation = _voiceGeneration;
    final held = _heldNote;
    setState(() => _voiceBusy = true);
    VoiceNote? note;
    try {
      note = held ?? await _voice!.stop();
    } on VoiceRecordException catch (e) {
      _showVoiceError(e.failure);
    } finally {
      if (mounted) {
        setState(() {
          _voiceBusy = false;
          _resetVoiceState();
        });
      }
    }
    if (note == null || generation != _voiceGeneration || _callActive) return;
    await _offerVoice(note);
  }

  /// The recording reached its limit. It stops and waits in the composer, so
  /// the sender can send it or cancel.
  Future<void> _onVoiceLimit() async {
    if (!_recording || _voiceBusy) return;
    final generation = _voiceGeneration;
    setState(() => _voiceBusy = true);
    VoiceNote? note;
    try {
      note = await _voice!.stop();
    } on VoiceRecordException catch (e) {
      _showVoiceError(e.failure);
    }
    if (!mounted) return;
    setState(() {
      _voiceBusy = false;
      if (note != null && generation == _voiceGeneration) {
        _recording = false;
        _heldNote = note;
        _voiceTicker?.cancel();
        _voiceTicker = null;
      } else {
        _resetVoiceState();
      }
    });
  }

  /// Stops and drops a recording, held or running.
  Future<void> _discardVoice() async {
    _voiceGeneration++;
    final voice = _voice;
    if (mounted) setState(_resetVoiceState);
    await voice?.cancel();
  }

  /// Asks before a back press drops the voice message in progress. On
  /// Discard the recording is cancelled and the page closes.
  Future<void> _confirmLeaveRecording() async {
    final l10n = AppLocalizations.of(context);
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.chatVoiceDiscardTitle),
        content: Text(l10n.chatVoiceDiscardBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.chatCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.chatVoiceDiscard),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    // The page closes at once; the recorder finishes cancelling after.
    unawaited(_discardVoice());
    Navigator.of(context).pop();
  }

  void _resetVoiceState() {
    _recording = false;
    _heldNote = null;
    _voiceTicker?.cancel();
    _voiceTicker = null;
  }

  /// Offers a finished voice note to the contact, under its own name.
  Future<void> _offerVoice(VoiceNote note) async {
    final l10n = AppLocalizations.of(context);
    final size = note.bytes.length;
    if (!isVoiceMime(note.mime) || size < 1) {
      _showVoiceError(VoiceFailure.unavailable);
      return;
    }
    if (voiceOfferRefused(mime: note.mime, size: size)) {
      _showVoiceError(VoiceFailure.unavailable, text: l10n.chatVoiceTooLong);
      return;
    }
    try {
      await widget.chat.offerFile(
        contact: widget.contactId,
        name: voiceFileName(
          widget.chat.clock().millisecondsSinceEpoch,
          note.extension,
        ),
        bytes: note.bytes,
        mime: note.mime,
        voice: true,
      );
      await _load();
    } catch (_) {
      // The error is not shown: its text names internal types and limits.
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.chatVoiceUnavailable)));
    }
  }

  void _showVoiceError(VoiceFailure failure, {String? text}) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final message =
        text ??
        switch (failure) {
          VoiceFailure.permission => l10n.chatVoicePermission,
          VoiceFailure.micPrivacy => l10n.chatVoiceMicPrivacy,
          VoiceFailure.needsParecord => l10n.chatVoiceNeedsParecord,
          VoiceFailure.unavailable => l10n.chatVoiceUnavailable,
        };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// The composer while a voice message is recorded or held: the elapsed time
  /// (or the limit notice), cancel, and send.
  Widget _recordingRow(
    AppLocalizations l10n,
    ChatTokens tokens,
    TextTheme textTheme,
  ) {
    final held = _heldNote != null;
    final scheme = Theme.of(context).colorScheme;
    final elapsed = _voice?.elapsed ?? Duration.zero;
    return Row(
      children: [
        IconButton(
          tooltip: l10n.chatVoiceCancel,
          style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: Icon(Icons.close, color: tokens.attachIcon),
          onPressed: _voiceBusy ? null : () => unawaited(_discardVoice()),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Container(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 12),
            decoration: BoxDecoration(
              color: tokens.fieldFill,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: [
                if (!held) ...[
                  Icon(
                    Icons.fiber_manual_record,
                    size: 12,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    held
                        ? l10n.chatVoiceTooLong
                        : l10n.chatVoiceRecording(formatVoiceDuration(elapsed)),
                    style: textTheme.bodyLarge?.copyWith(
                      color: tokens.fieldText,
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: l10n.chatVoiceSend,
          style: IconButton.styleFrom(
            backgroundColor: tokens.sendFill,
            foregroundColor: tokens.sendIcon,
            minimumSize: const Size(48, 48),
          ),
          icon: const Icon(Icons.send),
          onPressed: _voiceBusy ? null : () => unawaited(_sendVoice()),
        ),
      ],
    );
  }

  Future<void> _attachFile({_AttachmentKind? kind}) async {
    final l10n = AppLocalizations.of(context);
    List<XFile> picked = const [];
    try {
      if (kind == _AttachmentKind.gallery) {
        try {
          picked = await openFiles(
            acceptedTypeGroups: [
              XTypeGroup(
                label: l10n.chatPickMedia,
                mimeTypes: const [
                  'image/jpeg',
                  'image/png',
                  'image/webp',
                  'image/gif',
                  'video/mp4',
                  'video/quicktime',
                  'video/x-matroska',
                ],
                extensions: const [
                  'jpg',
                  'jpeg',
                  'png',
                  'webp',
                  'gif',
                  'mp4',
                  'mov',
                  'mkv',
                  'webm',
                ],
              ),
            ],
          );
        } catch (_) {
          picked = await openFiles();
        }
      } else if (kind == _AttachmentKind.audio) {
        try {
          picked = await openFiles(
            acceptedTypeGroups: [
              XTypeGroup(
                label: l10n.chatPickAudio,
                mimeTypes: const [
                  'audio/mpeg',
                  'audio/mp4',
                  'audio/wav',
                  'audio/ogg',
                  'audio/aac',
                  'audio/opus',
                ],
                extensions: const [
                  'mp3',
                  'm4a',
                  'wav',
                  'ogg',
                  'aac',
                  'opus',
                  'flac',
                ],
              ),
            ],
          );
        } catch (_) {
          picked = await openFiles();
        }
      } else if (kind == _AttachmentKind.document) {
        try {
          picked = await openFiles(
            acceptedTypeGroups: [
              XTypeGroup(
                label: l10n.chatPickDocuments,
                mimeTypes: const [
                  'application/pdf',
                  'text/plain',
                  'application/msword',
                  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                  'application/vnd.ms-excel',
                  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                  'application/zip',
                ],
                extensions: const [
                  'pdf',
                  'txt',
                  'doc',
                  'docx',
                  'xls',
                  'xlsx',
                  'ppt',
                  'pptx',
                  'zip',
                  'csv',
                ],
              ),
            ],
          );
        } catch (_) {
          picked = await openFiles();
        }
      } else {
        picked = await openFiles();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(offerErrorMessage(l10n, e))));
      return;
    }
    if (picked.isEmpty) return;
    final skipped = await sendPickedFiles(
      picked: [
        for (final file in picked)
          (
            name: file.name,
            read: file.readAsBytes,
            mime: file.mimeType ?? ChatFrames.detectMimeType(file.name),
          ),
      ],
      offer: (name, bytes, mime) => widget.chat.offerFile(
        contact: widget.contactId,
        name: name,
        bytes: bytes,
        mime: mime,
      ),
      onSent: _load,
    );
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    final notes = <String>[
      if (picked.length > maxFilesPerPick)
        l10n.chatFilesTooMany(maxFilesPerPick),
      if (skipped.length == 1)
        '${skipped.single.name}: ${offerErrorMessage(l10n, skipped.single.error)}'
      else if (skipped.isNotEmpty)
        l10n.chatFilesSkipped(
          skipped.length,
          skipped.map((s) => s.name).join(', '),
        ),
    ];
    if (notes.isEmpty) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(notes.join('\n'))));
  }

  void _showAttachmentMenu(AppLocalizations l10n) {
    final tokens = ChatTokens.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: tokens.header,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _AttachmentOption(
                icon: Icons.photo_library,
                color: const Color(0xFFAC44CF),
                label: l10n.chatAttachGallery,
                onTap: () {
                  Navigator.pop(context);
                  _attachFile(kind: _AttachmentKind.gallery);
                },
              ),
              _AttachmentOption(
                icon: Icons.insert_drive_file,
                color: const Color(0xFF5F66CD),
                label: l10n.chatAttachDocument,
                onTap: () {
                  Navigator.pop(context);
                  _attachFile(kind: _AttachmentKind.document);
                },
              ),
              _AttachmentOption(
                icon: Icons.headphones,
                color: const Color(0xFFF33D73),
                label: l10n.chatAttachAudio,
                onTap: () {
                  Navigator.pop(context);
                  _attachFile(kind: _AttachmentKind.audio);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _acceptFile(ChatMessage message) async {
    final fileId = message.fileId ?? message.id;
    await widget.chat.acceptFile(widget.contactId, fileId);
    await _load();
  }

  Future<void> _declineFile(ChatMessage message) async {
    final fileId = message.fileId ?? message.id;
    await widget.chat.declineFile(widget.contactId, fileId);
    await _load();
  }

  /// Opens a received file in another app. The file is kept encrypted, so
  /// the app opens a decrypted copy.
  Future<void> _openFile(ChatMessage message) async {
    final l10n = AppLocalizations.of(context);
    final failed = l10n.chatFileOpenFailed;
    try {
      if (kIsWeb) {
        final bytes = await widget.chat.store.readFile(message);
        downloadWebFile(bytes, message.fileName ?? 'file', message.fileMime);
        return;
      }
      final copy = await widget.chat.store.openCopy(message);
      if (defaultTargetPlatform == TargetPlatform.android) {
        // The native side picks the type from the file name, never from what
        // the peer said, and refuses types that are unsafe to open. There is
        // no fallback on Android: it would open what was refused.
        try {
          const channel = MethodChannel('sotto/android');
          await channel.invokeMethod<bool>('openFile', {'path': copy.path});
        } on PlatformException catch (e) {
          if (e.code == 'blocked_type' || e.code == 'no_app') {
            unawaited(widget.chat.store.files?.removeOpenCopy(copy));
          }
          _showSnack(openFileErrorMessage(l10n, e.code));
        }
        return;
      }
      await launchUrl(Uri.file(copy.path));
    } catch (e) {
      _showFileError(e, failed);
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _saveFileAs(ChatMessage message) async {
    final l10n = AppLocalizations.of(context);
    final failed = l10n.chatFileSaveFailed;
    try {
      final bytes = await widget.chat.store.readFile(message);
      final fileName = message.fileName ?? 'file';

      if (kIsWeb) {
        downloadWebFile(bytes, fileName, message.fileMime);
        _showSnack(l10n.chatFileDownloadingWeb(fileName));
        return;
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        // Only the native save is used. Nothing is written anywhere else: a
        // plain copy outside the app would leave the file unencrypted.
        String? saved;
        try {
          const channel = MethodChannel('sotto/android');
          saved = await channel.invokeMethod<String>('saveToDownloads', {
            'bytes': bytes,
            'name': fileName,
          });
        } on PlatformException catch (e) {
          _showSnack(
            e.code == 'permission_required'
                ? l10n.chatFileStoragePermission
                : failed,
          );
          return;
        }
        if (saved == null) {
          _showSnack(failed);
          return;
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            // The name actually used, which may differ, as "name (1).pdf".
            content: Text(l10n.chatFileSavedToDownloads(saved)),
            action: SnackBarAction(
              label: l10n.chatFileOpen,
              onPressed: () => _openFile(message),
            ),
          ),
        );
        return;
      }

      final location = await getSaveLocation(suggestedName: fileName);
      if (location == null) return;
      await XFile.fromData(
        bytes,
        name: fileName,
        mimeType: message.fileMime,
      ).saveTo(location.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).chatFileReceived)),
      );
    } catch (e) {
      _showFileError(e, failed);
    }
  }

  void _showFileError(Object error, String fallback) {
    if (!mounted) return;
    final text = fileErrorMessage(
      AppLocalizations.of(context),
      error,
      fallback,
    );
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _retry(ChatMessage message) async {
    await widget.chat.retry(widget.contactId, message.id);
    await _load();
  }

  Future<void> _queue(ChatMessage message) async {
    await widget.chat.queue(widget.contactId, message.id);
    await _load();
  }

  Future<void> _unqueue(ChatMessage message) async {
    await widget.chat.unqueue(widget.contactId, message.id);
    await _load();
  }

  Future<void> _handleUrlTap(String url) async {
    var target = url;
    if (target.startsWith('www.')) {
      target = 'https://$target';
    }
    final uri = Uri.tryParse(target);
    if (uri == null) return;

    if (uri.scheme == 'mailto') {
      try {
        await launchUrl(uri);
      } catch (_) {}
      return;
    }

    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.chatOpenLinkTitle),
        content: Text(l10n.chatOpenLinkBody(url)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.chatCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.chatOpenLink),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  void _copyMessage(ChatMessage message) {
    unawaited(
      Clipboard.setData(ClipboardData(text: message.fileName ?? message.text)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).chatCopied),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// The messages shown: all of them, or those whose text or file name holds
  /// the search.
  List<ChatMessage> _shownMessages() => _searchQuery.isEmpty
      ? _messages
      : _messages
            .where(
              (m) =>
                  m.text.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                  (m.fileName?.toLowerCase().contains(
                        _searchQuery.toLowerCase(),
                      ) ??
                      false),
            )
            .toList();

  GlobalKey _keyFor(String id) => _itemKeys.putIfAbsent(id, GlobalKey.new);

  /// Runs the menu item chosen for [message].
  void _onAction(ChatMessage message, MessageAction action) {
    switch (action) {
      case MessageAction.react:
        setState(() => _reactingId = message.id);
      case MessageAction.reply:
        _startReply(message);
      case MessageAction.forward:
        unawaited(_forward(message));
      case MessageAction.copy:
        _copyMessage(message);
      case MessageAction.star:
        unawaited(_toggleStar(message));
      case MessageAction.info:
        unawaited(showMessageInfo(context, message));
      case MessageAction.edit:
        _startEdit(message);
      case MessageAction.deleteForEveryone:
        unawaited(_deleteForEveryone(message));
      case MessageAction.deleteForMe:
        unawaited(_deleteMessage(message));
    }
  }

  /// Stars or unstars [message] on this device. Nothing is sent.
  Future<void> _toggleStar(ChatMessage message) async {
    await widget.chat.setStarred(
      widget.contactId,
      message.id,
      !message.starred,
    );
    await _load();
  }

  void _startReply(ChatMessage message) {
    final wasEditing = _editing != null;
    setState(() {
      _replyTo = message;
      _editing = null;
    });
    if (wasEditing) _input.clear();
    _inputFocusNode.requestFocus();
  }

  void _startEdit(ChatMessage message) {
    setState(() {
      _editing = message;
      _replyTo = null;
    });
    _input.value = TextEditingValue(
      text: message.text,
      selection: TextSelection.collapsed(offset: message.text.length),
    );
    _inputFocusNode.requestFocus();
  }

  /// Leaves reply or edit mode. Leaving an edit clears the box, which holds
  /// the text being edited.
  void _cancelComposerAction() {
    final wasEditing = _editing != null;
    setState(() {
      _replyTo = null;
      _editing = null;
    });
    if (wasEditing) _input.clear();
  }

  Future<void> _react(ChatMessage message, String emoji) async {
    setState(() => _reactingId = null);
    await widget.chat.react(widget.contactId, message.id, emoji);
    await _load();
  }

  Future<void> _forward(ChatMessage message) async {
    await forwardText(
      context,
      chat: widget.chat,
      contacts: widget.contacts?.contacts ?? const [],
      text: message.text,
    );
  }

  /// Deletes your message for everyone, once the user confirms. The other
  /// device may keep its copy, and the dialog says so.
  Future<void> _deleteForEveryone(ChatMessage message) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.chatDeleteForEveryoneTitle),
        content: Text(l10n.chatDeleteForEveryoneBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.chatCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.chatDeleteForEveryone),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.chat.deleteForEveryone(widget.contactId, message.id);
    _forgetMessage(message.id);
    await _load();
  }

  /// Drops the reply, edit and reaction state that points at message [id]
  /// once that message is deleted here.
  void _forgetMessage(String id) {
    final editingIt = _editing?.id == id;
    setState(() {
      if (_replyTo?.id == id) _replyTo = null;
      if (_reactingId == id) _reactingId = null;
      if (editingIt) _editing = null;
    });
    if (editingIt) _input.clear();
  }

  /// Scrolls to message [id], when it is among those shown. Items are built as
  /// they come into view, so a message far from the newest is reached by
  /// stepping down from the newest, a screen at a time, until it is built.
  /// A message that is not shown is not looked for, and nothing moves.
  void _jumpTo(String id) {
    if (!_shownMessages().any((m) => m.id == id)) return;
    final key = _keyFor(id);
    if (key.currentContext != null) {
      _reveal(key);
      return;
    }
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(0);
    _stepTo(key, _scrollController.position.viewportDimension * 0.8);
  }

  void _stepTo(GlobalKey key, double step) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (key.currentContext != null) {
        _reveal(key);
        return;
      }
      final position = _scrollController.position;
      if (position.pixels >= position.maxScrollExtent) return;
      _scrollController.jumpTo(
        math.min(position.maxScrollExtent, position.pixels + step),
      );
      _stepTo(key, step);
    });
    // A callback runs after a frame, and a jump that moves nothing draws none.
    WidgetsBinding.instance.scheduleFrame();
  }

  void _reveal(GlobalKey key) {
    final target = key.currentContext;
    if (target == null) return;
    unawaited(
      Scrollable.ensureVisible(
        target,
        alignment: 0.5,
        duration: const Duration(milliseconds: 250),
      ),
    );
  }

  /// Above the box, what the next send will do: the message a reply answers,
  /// or the message being edited. Its cancel button leaves that mode.
  Widget _composerContext(
    AppLocalizations l10n,
    ChatTokens tokens,
    TextTheme textTheme,
  ) {
    final editing = _editing;
    final reply = _replyTo;
    final text = editing?.text ?? reply?.fileName ?? reply?.text ?? '';
    return Container(
      margin: const EdgeInsetsDirectional.only(bottom: 6),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: tokens.fieldFill,
        borderRadius: BorderRadius.circular(12),
        border: BorderDirectional(
          start: BorderSide(color: tokens.sendFill, width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  editing != null ? l10n.chatEditing : l10n.chatReply,
                  style: textTheme.labelMedium?.copyWith(
                    color: tokens.sendFill,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(
                    color: tokens.fieldText,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: editing != null
                ? l10n.chatCancelEdit
                : l10n.chatCancelReply,
            style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: Icon(Icons.close, color: tokens.attachIcon),
            onPressed: _cancelComposerAction,
          ),
        ],
      ),
    );
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.chatDeleteMessageTitle),
        content: Text(l10n.chatDeleteMessageBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.chatCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.chatDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.chat.deleteMessage(widget.contactId, message.id);
    _forgetMessage(message.id);
    await _load();
  }

  /// Mutes or unmutes this chat on this device. Nothing is sent.
  Future<void> _toggleMute() async {
    final next = !_muted;
    await widget.chat.setMuted(widget.contactId, next);
    if (mounted) setState(() => _muted = next);
  }

  void _openStarred() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StarredPage(
          chat: widget.chat,
          contacts: widget.contacts,
          calls: widget.calls,
          sendTyping: widget.sendTyping,
          sendReadReceipts: widget.sendReadReceipts,
        ),
      ),
    );
  }

  Future<void> _deleteChat(AppLocalizations l10n) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.chatDeleteTitle),
        content: Text(l10n.chatDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.chatCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.chatDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.chat.close(widget.contactId);
    await widget.chat.deleteChat(widget.contactId);
    await _load();
  }

  Future<void> _chooseRetention(AppLocalizations l10n) async {
    final current = await widget.chat.store.retention(widget.contactId);
    if (!mounted) return;
    final options = [
      (Duration.zero, l10n.chatDisappearingOff),
      (const Duration(hours: 24), l10n.chatDisappearing24h),
      (const Duration(days: 7), l10n.chatDisappearing7d),
      (const Duration(days: 30), l10n.chatDisappearing30d),
    ];
    final selected = await showDialog<Duration>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.chatDisappearingTitle),
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 12),
            child: Text(
              l10n.chatDisappearingDesc,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          RadioGroup<Duration>(
            groupValue: current,
            onChanged: (val) => Navigator.of(context).pop(val),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (dur, label) in options)
                  RadioListTile<Duration>(value: dur, title: Text(label)),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected != null && selected != current) {
      await widget.chat.store.setRetention(widget.contactId, selected);
      if (mounted) setState(() => _retention = selected);
      await _load();
    }
  }

  /// The disappearing-messages time in words: whole days, then whole hours,
  /// then minutes.
  String _retentionText(Duration d, AppLocalizations l10n) {
    if (d.inHours % 24 == 0 && d.inDays > 1) {
      return l10n.chatRetentionDays(d.inDays);
    }
    if (d.inMinutes % 60 == 0 && d.inHours > 0) {
      return l10n.chatRetentionHours(d.inHours);
    }
    return l10n.chatRetentionMinutes(math.max(1, d.inMinutes));
  }

  /// An empty state that scrolls when the space is too short for it, so a
  /// large text size cannot run it into the composer.
  Widget _scrollableEmpty(Widget child) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Center(child: child),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = ChatTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    final now = widget.chat.clock();
    final displayed = _shownMessages();

    return PopScope(
      // A voice message being recorded, or held at its limit, is not dropped
      // by a back press without asking.
      canPop: !_showEmoji && !_isSearching && !_voiceActive,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_voiceActive) {
          unawaited(_confirmLeaveRecording());
          return;
        }
        if (_showEmoji) {
          setState(() => _showEmoji = false);
          return;
        }
        if (_isSearching) {
          setState(() {
            _isSearching = false;
            _searchQuery = '';
            _searchController.clear();
          });
          return;
        }
      },
      child: Scaffold(
        backgroundColor: tokens.body,
        appBar: AppBar(
          titleSpacing: 0,
          backgroundColor: tokens.header,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          iconTheme: IconThemeData(color: tokens.headerIcon),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: tokens.divider),
          ),
          title: _isSearching
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: l10n.chatSearchHint,
                    border: InputBorder.none,
                  ),
                  onChanged: (q) => setState(() => _searchQuery = q.trim()),
                )
              : Row(
                  children: [
                    InitialsAvatar(
                      name: widget.name,
                      avatar: widget.avatar,
                      radius: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  widget.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.titleMedium?.copyWith(
                                    color: tokens.headerTitle,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (widget.verified) ...[
                                const SizedBox(width: 4),
                                Semantics(
                                  label: l10n.chatVerifiedTooltip,
                                  child: Tooltip(
                                    message: l10n.chatVerifiedTooltip,
                                    excludeFromSemantics: true,
                                    child: Icon(
                                      Icons.verified,
                                      size: 16,
                                      color: tokens.verifiedIcon,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          // Only what is known: the peer is typing. Presence is
                          // not known, so no line claims it.
                          if (_peerIsTyping)
                            Text(
                              l10n.chatTyping(widget.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: tokens.verifiedIcon,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
          leading: _isSearching
              ? IconButton(
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() {
                    _isSearching = false;
                    _searchQuery = '';
                    _searchController.clear();
                  }),
                )
              : null,
          actions: [
            if (_isSearching) ...[
              if (_searchQuery.isNotEmpty)
                IconButton(
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() {
                    _searchQuery = '';
                    _searchController.clear();
                  }),
                ),
            ] else ...[
              if (widget.calls != null) ...[
                IconButton(
                  style: IconButton.styleFrom(minimumSize: const Size(44, 48)),
                  icon: const Icon(Icons.videocam),
                  tooltip: l10n.chatVideoCallTooltip(widget.name),
                  onPressed: _callActive
                      ? null
                      : () => unawaited(
                          widget.calls?.callContactId(
                            widget.contactId,
                            video: true,
                          ),
                        ),
                ),
                IconButton(
                  style: IconButton.styleFrom(minimumSize: const Size(44, 48)),
                  icon: const Icon(Icons.call),
                  tooltip: l10n.chatVoiceCallTooltip(widget.name),
                  onPressed: _callActive
                      ? null
                      : () => unawaited(
                          widget.calls?.callContactId(
                            widget.contactId,
                            video: false,
                          ),
                        ),
                ),
              ],
              IconButton(
                style: IconButton.styleFrom(minimumSize: const Size(44, 48)),
                icon: const Icon(Icons.search),
                tooltip: l10n.chatSearch,
                onPressed: () => setState(() => _isSearching = true),
              ),
              if (widget.calls == null ||
                  MediaQuery.sizeOf(context).width >= 360)
                IconButton(
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.timer_outlined),
                  tooltip: l10n.chatDisappearingTitle,
                  onPressed: () => unawaited(_chooseRetention(l10n)),
                ),
              PopupMenuButton<String>(
                padding: const EdgeInsets.all(12),
                onSelected: (value) {
                  if (value == 'disappearing') {
                    unawaited(_chooseRetention(l10n));
                  } else if (value == 'starred') {
                    _openStarred();
                  } else if (value == 'mute') {
                    unawaited(_toggleMute());
                  } else if (value == 'delete') {
                    unawaited(_deleteChat(l10n));
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'disappearing',
                    child: Row(
                      children: [
                        const Icon(Icons.timer_outlined, size: 20),
                        const SizedBox(width: 12),
                        Flexible(child: Text(l10n.chatDisappearingTitle)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'starred',
                    child: Row(
                      children: [
                        const Icon(Icons.star_outline, size: 20),
                        const SizedBox(width: 12),
                        Flexible(child: Text(l10n.chatStarredMessages)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'mute',
                    child: Row(
                      children: [
                        Icon(
                          _muted
                              ? Icons.notifications_outlined
                              : Icons.notifications_off_outlined,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(_muted ? l10n.chatUnmute : l10n.chatMute),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        const Icon(Icons.delete_outline, size: 20),
                        const SizedBox(width: 12),
                        Flexible(child: Text(l10n.chatDeleteMenu)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_retention case final r? when r > Duration.zero)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(0, 8, 0, 4),
                  child: Center(
                    child: InkWell(
                      onTap: () => unawaited(_chooseRetention(l10n)),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 48),
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          14,
                          6,
                          14,
                          6,
                        ),
                        decoration: BoxDecoration(
                          color: tokens.pillFill,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.hourglass_top,
                              size: 14,
                              color: tokens.pillIcon,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                l10n.chatDisappearingActive(
                                  _retentionText(r, l10n),
                                ),
                                style: textTheme.labelMedium?.copyWith(
                                  color: tokens.pillText,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_problem case final problem?)
                _ProblemBanner(
                  text: _problemText(l10n, problem),
                  dismiss: l10n.chatDismiss,
                  onDismiss: () => setState(() => _problem = null),
                ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    if (_showEmoji || _reactingId != null) {
                      setState(() {
                        _showEmoji = false;
                        _reactingId = null;
                      });
                    }
                  },
                  child: _messages.isEmpty
                      ? _scrollableEmpty(
                          EmptyState(
                            icon: Icons.chat_bubble_outline,
                            title: l10n.chatMessage,
                            message: widget.chat.hideIp()
                                ? l10n.chatEmptyHintRelay
                                : l10n.chatEmptyHint,
                          ),
                        )
                      : displayed.isEmpty
                      ? _scrollableEmpty(
                          EmptyState(
                            icon: Icons.search_off,
                            title: l10n.chatSearch,
                            message: l10n.chatSearchNoMatches,
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          padding: const EdgeInsetsDirectional.fromSTEB(
                            16,
                            12,
                            16,
                            12,
                          ),
                          itemCount: displayed.length,
                          itemBuilder: (context, index) {
                            // The list is shown reversed, so index 0 is the newest
                            // message. [displayed] runs oldest first.
                            final j = displayed.length - 1 - index;
                            final message = displayed[j];
                            final previous = j > 0 ? displayed[j - 1] : null;
                            final next = j < displayed.length - 1
                                ? displayed[j + 1]
                                : null;
                            final dayStart = needsDaySeparator(
                              previousClockMs: previous?.clockMs,
                              clockMs: message.clockMs,
                            );
                            final sameRunAbove =
                                !dayStart &&
                                previous != null &&
                                previous.outgoing == message.outgoing;
                            final lastInRun =
                                next == null ||
                                next.outgoing != message.outgoing ||
                                needsDaySeparator(
                                  previousClockMs: message.clockMs,
                                  clockMs: next.clockMs,
                                );
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (dayStart)
                                  _DaySeparator(
                                    day: DateTime.fromMillisecondsSinceEpoch(
                                      message.clockMs,
                                    ),
                                    now: now,
                                  ),
                                KeyedSubtree(
                                  key: _keyFor(message.id),
                                  child: Padding(
                                    padding: EdgeInsetsDirectional.only(
                                      top: sameRunAbove ? 2 : 10,
                                    ),
                                    child: _Bubble(
                                      message: message,
                                      lastInGroup: lastInRun,
                                      contactName: widget.name,
                                      l10n: l10n,
                                      store: widget.chat.store,
                                      clock: widget.chat.clock,
                                      reacting: _reactingId == message.id,
                                      onAction: (action) =>
                                          _onAction(message, action),
                                      onReact: (emoji) =>
                                          _react(message, emoji),
                                      onDismissReactions: () =>
                                          setState(() => _reactingId = null),
                                      onJump: _jumpTo,
                                      onRetry: _retry,
                                      onQueue: _queue,
                                      onUnqueue: _unqueue,
                                      onTapUrl: _handleUrlTap,
                                      onAccept: () => _acceptFile(message),
                                      onDecline: () => _declineFile(message),
                                      onOpen: () => _openFile(message),
                                      onSaveAs: () => _saveFileAs(message),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ),
              if (_peerIsTyping)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 4),
                    child: Container(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        12,
                        6,
                        12,
                        6,
                      ),
                      decoration: BoxDecoration(
                        color: tokens.typingFill,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: tokens.spinner,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            l10n.chatTyping(widget.name),
                            style: textTheme.labelMedium?.copyWith(
                              color: tokens.typingText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Container(
                decoration: BoxDecoration(
                  color: tokens.footer,
                  border: Border(top: BorderSide(color: tokens.divider)),
                ),
                padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      // With Hide my IP on, messages go through the relay, not direct.
                      widget.chat.hideIp()
                          ? l10n.chatRelayNote
                          : l10n.chatDirectNote,
                      textAlign: TextAlign.center,
                      style: textTheme.bodySmall?.copyWith(
                        color: tokens.footerNote,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (!_voiceActive && (_replyTo != null || _editing != null))
                      _composerContext(l10n, tokens, textTheme),
                    if (_voiceActive)
                      _recordingRow(l10n, tokens, textTheme)
                    else
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: tokens.fieldFill,
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(
                                  color: tokens.divider,
                                  width: 0.8,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 4,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  IconButton(
                                    tooltip: _showEmoji
                                        ? l10n.chatKeyboardTooltip
                                        : l10n.chatEmojiTooltip,
                                    style: IconButton.styleFrom(
                                      minimumSize: const Size(40, 48),
                                    ),
                                    icon: Icon(
                                      _showEmoji
                                          ? Icons.keyboard_alt_outlined
                                          : Icons.emoji_emotions_outlined,
                                      color: tokens.attachIcon,
                                      size: 24,
                                    ),
                                    onPressed: _toggleEmojiPicker,
                                  ),
                                  Expanded(
                                    child: TextField(
                                      controller: _input,
                                      focusNode: _inputFocusNode,
                                      onTap: () {
                                        if (_showEmoji) {
                                          setState(() => _showEmoji = false);
                                        }
                                      },
                                      minLines: 1,
                                      maxLines: 5,
                                      maxLength: maxTextChars,
                                      buildCounter: (
                                        _, {
                                        required currentLength,
                                        required isFocused,
                                        maxLength,
                                      }) => null,
                                      style: textTheme.bodyLarge?.copyWith(
                                        color: tokens.fieldText,
                                        fontSize: 15,
                                      ),
                                      textInputAction: TextInputAction.send,
                                      onSubmitted: (_) => _send(),
                                      decoration: InputDecoration(
                                        hintText: l10n.chatWriteHint,
                                        hintStyle: textTheme.bodyLarge
                                            ?.copyWith(
                                              color: tokens.fieldHint,
                                              fontSize: 15,
                                            ),
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        disabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        contentPadding:
                                            const EdgeInsetsDirectional.fromSTEB(
                                              0,
                                              12,
                                              8,
                                              12,
                                            ),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: l10n.chatAttachFile,
                                    style: IconButton.styleFrom(
                                      minimumSize: const Size(40, 48),
                                    ),
                                    icon: Transform.rotate(
                                      angle: -0.5,
                                      child: Icon(
                                        Icons.attach_file,
                                        color: tokens.attachIcon,
                                        size: 24,
                                      ),
                                    ),
                                    onPressed: () => _showAttachmentMenu(l10n),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _input,
                            builder: (context, value, _) {
                              final style = IconButton.styleFrom(
                                backgroundColor: tokens.sendFill,
                                foregroundColor: tokens.sendIcon,
                                minimumSize: const Size(48, 48),
                                elevation: 2,
                              );
                              if (value.text.trim().isEmpty) {
                                final blocked = _callActive || _voiceBusy;
                                return IconButton.filled(
                                  tooltip: _callActive
                                      ? l10n.chatVoiceInCall
                                      : l10n.chatVoiceMessage,
                                  style: style,
                                  icon: const Icon(Icons.mic, size: 22),
                                  onPressed: blocked
                                      ? null
                                      : () => unawaited(_startVoiceRecording()),
                                );
                              }
                              return IconButton.filled(
                                tooltip: l10n.chatSend,
                                style: style,
                                icon: const Icon(Icons.send, size: 20),
                                onPressed: _send,
                              );
                            },
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              if (_showEmoji)
                EmojiPickerPanel(
                  tokens: tokens,
                  onEmojiSelected: _onEmojiSelected,
                  onBackspace: _onEmojiBackspace,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Names the day of the messages below it.
class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.day, required this.now});

  /// The local day of the message below.
  final DateTime day;

  /// The current time, from the injected clock.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final material = MaterialLocalizations.of(context);
    final tokens = ChatTokens.of(context);
    final label = switch (chatDayLabel(day: day, now: now)) {
      ChatDayLabel.today => l10n.chatDayToday,
      ChatDayLabel.yesterday => l10n.chatDayYesterday,
      ChatDayLabel.other when day.year == now.year => material.formatMediumDate(
        day,
      ),
      ChatDayLabel.other => material.formatFullDate(day),
    };
    return Semantics(
      header: true,
      child: Center(
        child: Container(
          margin: const EdgeInsetsDirectional.fromSTEB(0, 16, 0, 16),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 4),
          decoration: BoxDecoration(
            color: tokens.dayChipFill,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: tokens.dayChipText,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProblemBanner extends StatelessWidget {
  const _ProblemBanner({
    required this.text,
    required this.dismiss,
    required this.onDismiss,
  });

  final String text;
  final String dismiss;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    return Container(
      width: double.infinity,
      color: tokens.bannerFill,
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: TextStyle(color: tokens.bannerText)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: tokens.bannerText,
              minimumSize: const Size(48, 48),
            ),
            onPressed: onDismiss,
            child: Text(dismiss),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.lastInGroup,
    required this.contactName,
    required this.l10n,
    required this.store,
    required this.clock,
    required this.reacting,
    required this.onAction,
    required this.onReact,
    required this.onDismissReactions,
    required this.onJump,
    required this.onRetry,
    required this.onQueue,
    required this.onUnqueue,
    required this.onTapUrl,
    required this.onAccept,
    required this.onDecline,
    required this.onOpen,
    required this.onSaveAs,
  });

  final ChatMessage message;

  /// Whether this is the last bubble of a run from one sender on one day.
  /// Only that bubble has the tail.
  final bool lastInGroup;

  /// The contact's name, for the status text and the screen reader label.
  final String contactName;
  final AppLocalizations l10n;

  /// Where the voice notes are kept, for playing them.
  final ChatStore store;

  /// The chat's clock. The menu offers edit and delete for everyone by it.
  final DateTime Function() clock;

  /// Whether the reaction choices are open for this message.
  final bool reacting;

  /// Runs the menu item chosen for this message.
  final ValueChanged<MessageAction> onAction;

  /// Sets your reaction to the emoji given, or removes it with ''.
  final ValueChanged<String> onReact;

  /// Closes the reaction choices without setting one.
  final VoidCallback onDismissReactions;

  /// Scrolls to the message with this id: the one this message quotes.
  final ValueChanged<String> onJump;

  final Future<void> Function(ChatMessage message) onRetry;
  final Future<void> Function(ChatMessage message) onQueue;
  final Future<void> Function(ChatMessage message) onUnqueue;
  final void Function(String url) onTapUrl;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onOpen;
  final VoidCallback onSaveAs;

  /// The time, in the device's clock format. An outgoing message shows when
  /// it was sent; an incoming one, when it arrived on this device.
  String _timeText(BuildContext context) {
    final local = DateTime.fromMillisecondsSinceEpoch(message.clockMs);
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }

  /// What an outgoing message shows after its time: its state, as an icon
  /// and words. Null for incoming messages, and for files not yet complete.
  ({IconData icon, Color iconColor, Color labelColor, String label})? _status(
    ChatTokens tokens,
  ) {
    if (!message.outgoing) return null;
    if (message.isAttachment) {
      if (message.fileStatus != 'completed') return null;
      return (
        icon: Icons.done,
        iconColor: tokens.sentSecondary,
        labelColor: tokens.sentSecondary,
        label: l10n.chatStatusDelivered,
      );
    }
    return switch (message.state) {
      ChatState.sending => (
        icon: Icons.schedule,
        iconColor: tokens.sentSecondary,
        labelColor: tokens.sentSecondary,
        label: l10n.chatStatusSending,
      ),
      ChatState.queued => (
        icon: Icons.hourglass_top,
        iconColor: tokens.sentSecondary,
        labelColor: tokens.sentSecondary,
        label: l10n.chatStatusQueued,
      ),
      ChatState.delivered => (
        icon: Icons.done,
        iconColor: tokens.sentSecondary,
        labelColor: tokens.sentSecondary,
        label: l10n.chatStatusDelivered,
      ),
      ChatState.read => (
        icon: Icons.done_all,
        iconColor: tokens.readTick,
        labelColor: tokens.sentText,
        label: l10n.chatStatusRead,
      ),
      ChatState.notSent => (
        icon: Icons.error_outline,
        iconColor: tokens.notSentIcon,
        labelColor: tokens.sentText,
        // A message no session opened for is "no answer" (the plan's wording).
        // Other failures say only "Not sent"; the banner explains them.
        label: message.reason == 'no-answer'
            ? l10n.chatStatusNotSentNoAnswer(contactName)
            : l10n.chatStatusNotSent,
      ),
      ChatState.received => null,
    };
  }

  /// A file's state in words, for the screen reader. The card shows it too.
  String? _fileStateWord() => switch (message.fileStatus) {
    'offered' =>
      message.outgoing ? l10n.chatFileOffer(message.fileName ?? '') : null,
    'transferring' =>
      message.outgoing ? l10n.chatStatusSending : l10n.chatStatusReceiving,
    'declined' => l10n.chatFileDeclined,
    'cancelled' => l10n.chatFileCancelled,
    'failed' => l10n.chatFileFailed,
    _ => null,
  };

  ButtonStyle _actionStyle(ChatTokens tokens) => TextButton.styleFrom(
    foregroundColor: tokens.sentText,
    minimumSize: const Size(48, 48),
    visualDensity: VisualDensity.standard,
  );

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    final outgoing = message.outgoing;
    final isFile = message.isAttachment;
    final deleted = message.deletedForAll;
    // A voice note is what the offer said it was. Other audio is an ordinary
    // file, whatever its type.
    final isVoice = isFile && message.voiceNote;
    final fg = outgoing ? tokens.sentText : tokens.receivedText;
    final secondary = outgoing
        ? tokens.sentSecondary
        : tokens.receivedSecondary;
    final linkColor = outgoing ? tokens.sentText : tokens.receivedLink;
    final time = _timeText(context);
    final stateStatus = _status(tokens);
    // A deleted message shows no state: its text and its queue are gone.
    final status = deleted ? null : stateStatus;
    final name = isVoice
        ? l10n.chatVoiceMessage
        : (message.fileName ?? message.text);
    final edited = !deleted && message.editedAt != null;
    final forwarded = !deleted && message.forwarded;
    final showRetry =
        outgoing && !isFile && !deleted && message.state == ChatState.notSent;
    final showCancelQueue =
        outgoing && !isFile && !deleted && message.state == ChatState.queued;

    // One label per bubble: the time, the state, the text and the marks.
    final spoken = outgoing
        ? l10n.chatBubbleSemanticsOwn(
            time,
            deleted
                ? l10n.chatMessageDeleted
                : (stateStatus?.label ??
                      _fileStateWord() ??
                      l10n.chatStatusSending),
            isFile ? name : message.text,
          )
        : l10n.chatBubbleSemanticsOther(
            contactName,
            time,
            isFile && _fileStateWord() != null
                ? '$name (${_fileStateWord()})'
                : (isFile
                      ? name
                      : (deleted ? l10n.chatMessageDeleted : message.text)),
          );
    final marks = [
      if (edited) l10n.chatEdited,
      if (forwarded) l10n.chatForwarded,
    ].join(', ');
    final label = marks.isEmpty ? spoken : '$spoken, $marks';

    final baseText = (textTheme.bodyLarge ?? const TextStyle()).copyWith(
      fontSize: 15,
      height: 1.4,
    );
    final labelStyle = textTheme.labelMedium?.copyWith(color: secondary);

    final bubble = GestureDetector(
      onSecondaryTapUp: (details) => showMessageContextMenu(
        context,
        position: details.globalPosition,
        message: message,
        now: clock(),
        onSelected: onAction,
      ),
      onLongPress: () => showMessageSheet(
        context,
        message: message,
        now: clock(),
        onSelected: onAction,
      ),
      child: Semantics(
        container: true,
        label: label,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(MediaQuery.sizeOf(context).width * 0.78, 560),
          ),
          child: IntrinsicWidth(
            child: Container(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 14, 8),
              decoration: BoxDecoration(
                color: outgoing ? tokens.sentFill : tokens.receivedFill,
                borderRadius: BorderRadiusDirectional.only(
                  topStart: const Radius.circular(18),
                  topEnd: const Radius.circular(18),
                  bottomStart: Radius.circular(
                    !outgoing && lastInGroup ? 4 : 18,
                  ),
                  bottomEnd: Radius.circular(outgoing && lastInGroup ? 4 : 18),
                ),
                border: outgoing
                    ? null
                    : Border.all(color: tokens.receivedBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.replyTo case final quote? when !deleted)
                    ExcludeSemantics(
                      child: _QuoteBlock(
                        quote: quote,
                        outgoing: outgoing,
                        l10n: l10n,
                        style: baseText.copyWith(
                          fontSize: 13,
                          color: secondary,
                        ),
                        onTap: () => onJump(quote.id),
                      ),
                    ),
                  if (isVoice)
                    _VoiceCard(
                      message: message,
                      outgoing: outgoing,
                      l10n: l10n,
                      store: store,
                      onAccept: onAccept,
                      onDecline: onDecline,
                    )
                  else if (isFile)
                    _FileCard(
                      message: message,
                      outgoing: outgoing,
                      l10n: l10n,
                      store: store,
                      onAccept: onAccept,
                      onDecline: onDecline,
                      onOpen: onOpen,
                      onSaveAs: onSaveAs,
                    )
                  else if (deleted)
                    ExcludeSemantics(
                      child: Text(
                        l10n.chatMessageDeleted,
                        style: baseText.copyWith(
                          color: secondary,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    )
                  else
                    ExcludeSemantics(
                      child: _LinkifiedText(
                        text: message.text,
                        style: baseText.copyWith(color: fg),
                        linkStyle: baseText.copyWith(
                          color: linkColor,
                          decoration: TextDecoration.underline,
                          fontWeight: FontWeight.w600,
                        ),
                        onTapUrl: onTapUrl,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 2,
                    children: [
                      ExcludeSemantics(child: Text(time, style: labelStyle)),
                      if (edited)
                        ExcludeSemantics(
                          child: Text(l10n.chatEdited, style: labelStyle),
                        ),
                      if (forwarded)
                        ExcludeSemantics(
                          child: Text(l10n.chatForwarded, style: labelStyle),
                        ),
                      if (status != null)
                        ExcludeSemantics(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                status.icon,
                                size: 14,
                                color: status.iconColor,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  status.label,
                                  style: textTheme.labelMedium?.copyWith(
                                    color: status.labelColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (showRetry)
                        TextButton(
                          style: _actionStyle(tokens),
                          onPressed: () => onRetry(message),
                          child: Text(l10n.chatRetry),
                        ),
                      if (showRetry)
                        TextButton(
                          style: _actionStyle(tokens),
                          onPressed: () => onQueue(message),
                          child: Text(l10n.chatQueue),
                        ),
                      if (showCancelQueue)
                        TextButton(
                          style: _actionStyle(tokens),
                          onPressed: () => onUnqueue(message),
                          child: Text(l10n.chatCancelQueue),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // The reactions sit under the bubble, on its side.
    return Align(
      alignment: outgoing
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: outgoing
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          bubble,
          ReactionBar(
            reactions: deleted ? const {} : message.reactions,
            peerName: contactName,
            choosing: reacting && !deleted,
            onReact: onReact,
            onDismiss: onDismissReactions,
          ),
        ],
      ),
    );
  }
}

/// The message a reply quotes, above the reply's text. Tapping it jumps to
/// that message when it is shown. A quote whose text is gone reads as
/// deleted.
class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({
    required this.quote,
    required this.outgoing,
    required this.l10n,
    required this.style,
    required this.onTap,
  });

  final ChatReply quote;
  final bool outgoing;
  final AppLocalizations l10n;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final gone = quote.text.isEmpty;
    final accent = outgoing ? tokens.sentText : tokens.receivedLink;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsetsDirectional.only(bottom: 6),
        padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 8, 4),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: BorderDirectional(start: BorderSide(color: accent, width: 3)),
        ),
        child: Text(
          gone ? l10n.chatMessageDeleted : quote.text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: gone ? style.copyWith(fontStyle: FontStyle.italic) : style,
        ),
      ),
    );
  }
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.message,
    required this.outgoing,
    required this.l10n,
    required this.store,
    required this.onAccept,
    required this.onDecline,
    required this.onOpen,
    required this.onSaveAs,
  });

  final ChatMessage message;
  final bool outgoing;
  final AppLocalizations l10n;
  final ChatStore store;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onOpen;
  final VoidCallback onSaveAs;

  static bool isImageFile(String? mime, String? name) {
    final m = (mime ?? '').toLowerCase();
    final n = (name ?? '').toLowerCase();
    return m.startsWith('image/') ||
        n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp');
  }

  IconData _fileIcon(String? mime, String? name) {
    final m = (mime ?? '').toLowerCase();
    final n = (name ?? '').toLowerCase();
    if (isImageFile(mime, name)) {
      return Icons.image_outlined;
    }
    if (m.startsWith('video/') ||
        n.endsWith('.mp4') ||
        n.endsWith('.mkv') ||
        n.endsWith('.mov')) {
      return Icons.videocam_outlined;
    }
    if (m.startsWith('audio/') ||
        n.endsWith('.mp3') ||
        n.endsWith('.wav') ||
        n.endsWith('.ogg') ||
        n.endsWith('.m4a')) {
      return Icons.audio_file_outlined;
    }
    if (m == 'application/pdf' || n.endsWith('.pdf')) {
      return Icons.picture_as_pdf_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    final name = message.fileName ?? message.text;
    final size = message.fileSize != null
        ? _formatFileSize(message.fileSize!)
        : '';
    final status = message.fileStatus ?? (outgoing ? 'completed' : 'offered');
    final icon = _fileIcon(message.fileMime, message.fileName);
    final fg = outgoing ? tokens.sentText : tokens.receivedText;
    final secondary = outgoing
        ? tokens.sentSecondary
        : tokens.receivedSecondary;
    final tileFill = outgoing ? tokens.sentFileTile : tokens.receivedFileTile;
    final tileIcon = outgoing ? tokens.sentText : tokens.receivedFileIcon;
    final isImg = isImageFile(message.fileMime, message.fileName);
    final isDone = status == 'completed';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isImg && isDone) ...[
          _ImageThumbnail(
            message: message,
            store: store,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _ImageViewerPage(
                    message: message,
                    store: store,
                    onOpen: onOpen,
                    onSaveAs: onSaveAs,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
        ],
        ExcludeSemantics(
          child: InkWell(
            onTap: isDone ? onOpen : null,
            borderRadius: BorderRadius.circular(10),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: tileFill,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 28, color: tileIcon),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(color: fg),
                      ),
                      if (size.isNotEmpty)
                        Text(
                          size,
                          style: textTheme.labelMedium?.copyWith(
                            color: secondary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildStatusContent(tokens, textTheme, status),
      ],
    );
  }

  Widget _buildStatusContent(
    ChatTokens tokens,
    TextTheme textTheme,
    String status,
  ) {
    final secondary = outgoing
        ? tokens.sentSecondary
        : tokens.receivedSecondary;
    final label = textTheme.labelMedium;
    switch (status) {
      case 'offered':
        if (!outgoing) {
          return Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  backgroundColor: tokens.acceptFill,
                  foregroundColor: tokens.acceptText,
                ),
                onPressed: onAccept,
                child: Text(l10n.chatFileAccept),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: tokens.receivedSecondary,
                ),
                onPressed: onDecline,
                child: Text(l10n.chatFileDecline),
              ),
            ],
          );
        }
        return ExcludeSemantics(
          child: Text(
            l10n.chatFileOffer(message.fileName ?? ''),
            style: label?.copyWith(color: secondary),
          ),
        );
      case 'transferring':
        // No progress figure: the app does not track one for a file.
        return ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                outgoing ? l10n.chatStatusSending : l10n.chatStatusReceiving,
                style: label?.copyWith(color: secondary),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: 140,
                child: LinearProgressIndicator(
                  color: outgoing ? tokens.sentText : tokens.receivedLink,
                  backgroundColor: secondary.withValues(alpha: 0.3),
                ),
              ),
            ],
          ),
        );
      case 'completed':
        return Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton.icon(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: outgoing
                    ? tokens.sentText
                    : tokens.receivedText,
              ),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(l10n.chatFileOpen),
              onPressed: onOpen,
            ),
            if (!outgoing)
              TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: tokens.receivedText,
                ),
                icon: const Icon(Icons.download, size: 18),
                label: Text(l10n.chatFileSaveAs),
                onPressed: onSaveAs,
              ),
          ],
        );
      case 'declined':
        return ExcludeSemantics(
          child: Text(
            l10n.chatFileDeclined,
            style: label?.copyWith(
              color: secondary,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      case 'cancelled':
        return ExcludeSemantics(
          child: Text(
            l10n.chatFileCancelled,
            style: label?.copyWith(
              color: secondary,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      case 'failed':
        return ExcludeSemantics(
          child: Text(
            l10n.chatFileFailed,
            style: label?.copyWith(
              color: secondary,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

/// Thumbnail rendered for image attachments.
class _ImageThumbnail extends StatefulWidget {
  const _ImageThumbnail({
    required this.message,
    required this.store,
    required this.onTap,
  });

  final ChatMessage message;
  final ChatStore store;
  final VoidCallback onTap;

  @override
  State<_ImageThumbnail> createState() => _ImageThumbnailState();
}

class _ImageThumbnailState extends State<_ImageThumbnail> {
  Uint8List? _bytes;
  ({int width, int height})? _size;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await widget.store.readFile(widget.message);
      // The header is read first: an image too large to decode safely is
      // not shown at all. The file card below still offers it.
      final size = await safeImageSize(b);
      if (mounted) {
        setState(() {
          _bytes = size == null ? null : b;
          _size = size;
          _error = size == null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = true;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        height: 180,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error || _bytes == null) {
      final tokens = ChatTokens.of(context);
      final color = widget.message.outgoing
          ? tokens.sentSecondary
          : tokens.receivedSecondary;
      return Row(
        children: [
          Icon(Icons.broken_image_outlined, size: 20, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              AppLocalizations.of(context).chatImageLoadFailed,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: color),
            ),
          ),
        ],
      );
    }
    return GestureDetector(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxHeight: 260,
            minWidth: double.infinity,
          ),
          // Decoded no wider than the screen, never at full size. The height
          // follows, as the aspect ratio is kept. (The bubble sizes itself
          // by intrinsic width, so a LayoutBuilder cannot be used here.)
          child: Image.memory(
            _bytes!,
            fit: BoxFit.cover,
            cacheWidth: math.max(
              1,
              math.min(
                _size!.width,
                (MediaQuery.sizeOf(context).width *
                        MediaQuery.devicePixelRatioOf(context))
                    .ceil(),
              ),
            ),
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// Full screen image viewer with pinch-to-zoom and save actions.
class _ImageViewerPage extends StatefulWidget {
  const _ImageViewerPage({
    required this.message,
    required this.store,
    required this.onOpen,
    required this.onSaveAs,
  });

  final ChatMessage message;
  final ChatStore store;
  final VoidCallback onOpen;
  final VoidCallback onSaveAs;

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await widget.store.readFile(widget.message);
      final size = await safeImageSize(b);
      if (mounted) {
        setState(() {
          _bytes = size == null ? null : b;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = widget.message.fileName ?? l10n.chatImage;
    final failed = Text(
      l10n.chatImageLoadFailed,
      style: const TextStyle(color: Colors.white70),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.8),
        foregroundColor: Colors.white,
        title: Text(name, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: l10n.chatImageOpenWith,
            onPressed: widget.onOpen,
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: l10n.chatImageSave,
            onPressed: widget.onSaveAs,
          ),
        ],
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator(color: Colors.white)
            : _bytes == null
            ? failed
            : InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                // Decoded to at most maxViewerSide on its long side.
                child: Image(
                  image: ResizeImage(
                    MemoryImage(_bytes!),
                    width: maxViewerSide,
                    height: maxViewerSide,
                    policy: ResizeImagePolicy.fit,
                  ),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => failed,
                ),
              ),
      ),
    );
  }
}

enum _AttachmentKind { gallery, document, audio }

class _AttachmentOption extends StatelessWidget {
  const _AttachmentOption({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: color,
              child: Icon(icon, color: Colors.white, size: 28),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

/// A voice note in a bubble: a play or pause button (48 dp), a progress bar
/// and the length. The other states of a transfer read as the file card does.
class _VoiceCard extends StatefulWidget {
  const _VoiceCard({
    required this.message,
    required this.outgoing,
    required this.l10n,
    required this.store,
    required this.onAccept,
    required this.onDecline,
  });

  final ChatMessage message;
  final bool outgoing;
  final AppLocalizations l10n;
  final ChatStore store;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  State<_VoiceCard> createState() => _VoiceCardState();
}

class _VoiceCardState extends State<_VoiceCard> {
  late final VoicePlayer _player = VoicePlayer(copies: widget.store.files);

  /// Bytes are being read, so the button waits.
  bool _loading = false;

  /// The note could not be read to play it.
  bool _failed = false;

  @override
  void dispose() {
    unawaited(_player.dispose());
    super.dispose();
  }

  /// Plays, pauses or carries on, as the player stands. Playback starts only
  /// on a tap.
  Future<void> _togglePlay() async {
    final state = _player.playback.value.state;
    if (state == PlayerState.playing) {
      await _player.pause();
      return;
    }
    if (state == PlayerState.paused) {
      await _player.resume();
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final bytes = await widget.store.readFile(widget.message);
      await _player.start(
        bytes,
        mime: baseMime(widget.message.fileMime ?? ''),
        name: widget.message.fileName ?? 'voice',
      );
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final tokens = ChatTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    final outgoing = widget.outgoing;
    final message = widget.message;
    final status = message.fileStatus ?? (outgoing ? 'completed' : 'offered');
    final fg = outgoing ? tokens.sentText : tokens.receivedText;
    final secondary = outgoing
        ? tokens.sentSecondary
        : tokens.receivedSecondary;
    final label = textTheme.labelMedium;

    switch (status) {
      case 'completed':
        if (!widget.store.hasVoice(message)) {
          return ExcludeSemantics(
            child: Text(
              l10n.chatVoiceUnavailable,
              style: label?.copyWith(
                color: secondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          );
        }
        return _playRow(tokens, textTheme, fg, secondary);
      case 'offered':
        if (outgoing) {
          // Offered, and waiting for the contact to accept: not yet sent.
          return ExcludeSemantics(
            child: Text(
              l10n.chatFileOffer(message.fileName ?? ''),
              style: label?.copyWith(color: secondary),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Text(
                l10n.chatVoiceMessage,
                style: textTheme.titleSmall?.copyWith(color: fg),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    backgroundColor: tokens.acceptFill,
                    foregroundColor: tokens.acceptText,
                  ),
                  onPressed: widget.onAccept,
                  child: Text(l10n.chatFileAccept),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    foregroundColor: tokens.receivedSecondary,
                  ),
                  onPressed: widget.onDecline,
                  child: Text(l10n.chatFileDecline),
                ),
              ],
            ),
          ],
        );
      case 'transferring':
        return ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                outgoing ? l10n.chatStatusSending : l10n.chatStatusReceiving,
                style: label?.copyWith(color: secondary),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: 160,
                child: LinearProgressIndicator(
                  color: fg,
                  backgroundColor: secondary.withValues(alpha: 0.3),
                ),
              ),
            ],
          ),
        );
      case 'declined':
        return ExcludeSemantics(
          child: Text(
            l10n.chatFileDeclined,
            style: label?.copyWith(
              color: secondary,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      case 'cancelled':
        return ExcludeSemantics(
          child: Text(
            l10n.chatFileCancelled,
            style: label?.copyWith(
              color: secondary,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      case 'failed':
        return ExcludeSemantics(
          child: Text(
            l10n.chatFileFailed,
            style: label?.copyWith(
              color: secondary,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// The play row. The button stays out of the excluded semantics, so a
  /// screen reader can reach it; the bar and the length are read in the
  /// bubble's label.
  Widget _playRow(
    ChatTokens tokens,
    TextTheme textTheme,
    Color fg,
    Color secondary,
  ) {
    final l10n = widget.l10n;
    return ValueListenableBuilder<VoicePlayback>(
      valueListenable: _player.playback,
      builder: (context, playback, _) {
        final playing = playback.state == PlayerState.playing;
        final active = playing || playback.state == PlayerState.paused;
        final total = playback.duration;
        final fraction = total == null || total.inMilliseconds == 0
            ? 0.0
            : (playback.position.inMilliseconds / total.inMilliseconds).clamp(
                0.0,
                1.0,
              );
        final time = switch ((total, active)) {
          (null, false) => '--:--',
          (null, true) => formatVoiceDuration(playback.position),
          (final length?, true) =>
            '${formatVoiceDuration(playback.position)} / '
                '${formatVoiceDuration(length)}',
          (final length?, false) => formatVoiceDuration(length),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  style: IconButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    foregroundColor: fg,
                  ),
                  tooltip: playing ? l10n.chatVoicePause : l10n.chatVoicePlay,
                  icon: _loading
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: fg,
                          ),
                        )
                      : Icon(
                          playing ? Icons.pause : Icons.play_arrow,
                          size: 28,
                        ),
                  onPressed: _loading ? null : () => unawaited(_togglePlay()),
                ),
                const SizedBox(width: 8),
                // Shrinks on a narrow bubble rather than running past its edge.
                Flexible(
                  child: SizedBox(
                    width: 160,
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LinearProgressIndicator(
                            value: fraction,
                            color: fg,
                            backgroundColor: secondary.withValues(alpha: 0.3),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            time,
                            style: textTheme.labelMedium?.copyWith(
                              color: secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_failed)
              ExcludeSemantics(
                child: Text(
                  l10n.chatVoiceUnavailable,
                  style: textTheme.labelMedium?.copyWith(
                    color: secondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LinkifiedText extends StatefulWidget {
  const _LinkifiedText({
    required this.text,
    required this.style,
    required this.linkStyle,
    required this.onTapUrl,
  });

  final String text;
  final TextStyle style;
  final TextStyle linkStyle;
  final void Function(String url) onTapUrl;

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  static final _urlRegex = RegExp(
    r'(https?:\/\/[^\s<>"{}|\\^`]+|mailto:[^\s<>"{}|\\^`]+|www\.[^\s<>"{}|\\^`]+)',
    caseSensitive: false,
  );
  static final _trailingPunctuation = RegExp(r'[.,;:)!?]+$');

  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  List<InlineSpan> _buildSpans() {
    _clearRecognizers();
    final matches = _urlRegex.allMatches(widget.text).toList();
    if (matches.isEmpty) {
      return [TextSpan(text: widget.text, style: widget.style)];
    }

    final spans = <InlineSpan>[];
    var lastIndex = 0;

    for (final match in matches) {
      if (match.start > lastIndex) {
        spans.add(
          TextSpan(
            text: widget.text.substring(lastIndex, match.start),
            style: widget.style,
          ),
        );
      }

      var rawUrl = match.group(0)!;
      var punctuation = '';
      final pMatch = _trailingPunctuation.firstMatch(rawUrl);
      if (pMatch != null) {
        punctuation = rawUrl.substring(pMatch.start);
        rawUrl = rawUrl.substring(0, pMatch.start);
      }

      final url = rawUrl;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onTapUrl(url);
      _recognizers.add(recognizer);

      spans.add(
        TextSpan(text: url, style: widget.linkStyle, recognizer: recognizer),
      );

      if (punctuation.isNotEmpty) {
        spans.add(TextSpan(text: punctuation, style: widget.style));
      }

      lastIndex = match.end;
    }

    if (lastIndex < widget.text.length) {
      spans.add(
        TextSpan(text: widget.text.substring(lastIndex), style: widget.style),
      );
    }

    return spans;
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(TextSpan(children: _buildSpans()));
  }
}
