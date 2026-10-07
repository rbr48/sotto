import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sotto/call/media_engine.dart';
import 'package:sotto/call/webrtc_media_engine.dart';

StatsReport report(String type, Map<String, Object?> values) =>
    StatsReport('$type-${values.hashCode}', type, 0, values);

void main() {
  group('roundTripFromStats', () {
    test('uses the worst remote-inbound-rtp round trip, in seconds', () {
      final rtt = roundTripFromStats([
        report('remote-inbound-rtp', {'kind': 'audio', 'roundTripTime': 0.012}),
        report('remote-inbound-rtp', {'kind': 'video', 'roundTripTime': 0.045}),
      ]);
      expect(rtt, const Duration(milliseconds: 45));
    });

    test("ignores the candidate pair (Firefox reports it in milliseconds)", () {
      // Seen in Firefox 142 on a local call: the pair says 24 (ms), the
      // RTCP reports say 0.002 s.
      final reports = [
        report('candidate-pair', {
          'nominated': true,
          'selected': true,
          'currentRoundTripTime': 24,
        }),
        report('remote-inbound-rtp', {
          'kind': 'audio',
          'roundTripTime': 0.002274,
        }),
      ];
      final rtt = roundTripFromStats(reports);
      expect(rtt?.inMicroseconds, 2274);
      expect(
        QualitySample(roundTrip: rtt, packetLoss: 0).quality,
        CallQuality.good,
      );
    });

    test('no RTCP report yet: no round trip', () {
      expect(
        roundTripFromStats([
          report('candidate-pair', {
            'nominated': true,
            'currentRoundTripTime': 1,
          }),
          report('remote-inbound-rtp', {'kind': 'video'}),
        ]),
        isNull,
      );
    });
  });
}
