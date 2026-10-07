import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Events received from the Phase 1 dev-room relay (`server/src/devRooms.ts`).
///
/// This plaintext signaling exists only for the WebRTC proof of concept and is
/// replaced by the end-to-end encrypted relay protocol in Phase 3.
sealed class DevRoomEvent {
  const DevRoomEvent();

  /// Parses a server message, returning `null` for anything unrecognised.
  static DevRoomEvent? parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    switch (decoded['type']) {
      case 'joined':
        final peers = decoded['peers'];
        return peers is int ? RoomJoined(peers) : null;
      case 'peer-joined':
        return const PeerJoined();
      case 'peer-left':
        return const PeerLeft();
      case 'signal':
        final data = decoded['data'];
        return data is Map<String, dynamic> ? SignalReceived(data) : null;
      case 'error':
        final code = decoded['code'];
        return code is String ? RoomError(code) : null;
      default:
        return null;
    }
  }
}

/// We joined the room; [peers] is how many others were already in it.
final class RoomJoined extends DevRoomEvent {
  const RoomJoined(this.peers);
  final int peers;
}

final class PeerJoined extends DevRoomEvent {
  const PeerJoined();
}

final class PeerLeft extends DevRoomEvent {
  const PeerLeft();
}

final class SignalReceived extends DevRoomEvent {
  const SignalReceived(this.data);
  final Map<String, dynamic> data;
}

final class RoomError extends DevRoomEvent {
  const RoomError(this.code);
  final String code;
}

/// Thin client for the dev-room relay.
class DevRoomSignaling {
  DevRoomSignaling._(this._channel);

  final WebSocketChannel _channel;

  static Future<DevRoomSignaling> connect(Uri url) async {
    final channel = WebSocketChannel.connect(url);
    await channel.ready;
    return DevRoomSignaling._(channel);
  }

  /// Parsed events; unrecognised messages are dropped. Completes when the
  /// connection closes.
  Stream<DevRoomEvent> get events => _channel.stream
      .where((message) => message is String)
      .map((message) => DevRoomEvent.parse(message as String))
      .where((event) => event != null)
      .cast<DevRoomEvent>();

  void join(String room) => _send({'type': 'join', 'room': room});

  void signal(Map<String, dynamic> data) =>
      _send({'type': 'signal', 'data': data});

  Future<void> close() async {
    _send({'type': 'leave'});
    await _channel.sink.close();
  }

  void _send(Map<String, dynamic> message) =>
      _channel.sink.add(jsonEncode(message));
}
