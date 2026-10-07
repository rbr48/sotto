import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/poc/dev_room_signaling.dart';

void main() {
  group('DevRoomEvent.parse', () {
    test('parses every server message type', () {
      expect(
        DevRoomEvent.parse('{"type":"joined","peers":1}'),
        isA<RoomJoined>().having((e) => e.peers, 'peers', 1),
      );
      expect(DevRoomEvent.parse('{"type":"peer-joined"}'), isA<PeerJoined>());
      expect(DevRoomEvent.parse('{"type":"peer-left"}'), isA<PeerLeft>());
      expect(
        DevRoomEvent.parse(
          '{"type":"signal","data":{"kind":"offer","sdp":"v=0"}}',
        ),
        isA<SignalReceived>().having((e) => e.data['kind'], 'kind', 'offer'),
      );
      expect(
        DevRoomEvent.parse('{"type":"error","code":"room-full"}'),
        isA<RoomError>().having((e) => e.code, 'code', 'room-full'),
      );
    });

    test('rejects malformed or unknown messages', () {
      expect(DevRoomEvent.parse('not json'), isNull);
      expect(DevRoomEvent.parse('[1,2]'), isNull);
      expect(DevRoomEvent.parse('{"type":"joined","peers":"1"}'), isNull);
      expect(DevRoomEvent.parse('{"type":"signal","data":"text"}'), isNull);
      expect(DevRoomEvent.parse('{"type":"surprise"}'), isNull);
    });
  });
}
