import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/call/media_engine.dart';
import 'package:sotto/call/video_adapter.dart';

void main() {
  /// Feeds [samples] and returns the levels it changed to.
  List<VideoLevel> feed(VideoAdapter adapter, List<CallQuality?> samples) => [
    for (final sample in samples) ?adapter.onSample(sample),
  ];

  const good = CallQuality.good;
  const fair = CallQuality.fair;
  const poor = CallQuality.poor;

  test('a short dip changes nothing', () {
    final adapter = VideoAdapter();
    expect(feed(adapter, [good, poor, good, fair, fair, good, null]), isEmpty);
    expect(adapter.level, VideoLevel.full);
  });

  test('a weak upload steps the video down, then pauses it', () {
    final adapter = VideoAdapter();
    expect(feed(adapter, List.filled(7, poor)), [
      VideoLevel.reduced,
      VideoLevel.low,
      VideoLevel.paused,
    ]);
    expect(feed(adapter, List.filled(10, poor)), isEmpty, reason: 'stays');
  });

  test('a fair upload lowers the video once but never pauses it', () {
    final adapter = VideoAdapter();
    expect(feed(adapter, List.filled(20, fair)), [VideoLevel.reduced]);
  });

  test('a good upload brings video back slowly, one step at a time', () {
    final adapter = VideoAdapter();
    feed(adapter, List.filled(7, poor));
    expect(adapter.level, VideoLevel.paused);
    expect(feed(adapter, List.filled(7, good)), isEmpty, reason: 'not yet');
    expect(feed(adapter, [good]), [VideoLevel.low]);
    expect(feed(adapter, List.filled(10, good)), [
      VideoLevel.reduced,
      VideoLevel.full,
    ]);
  });

  test('reset goes back to full video', () {
    final adapter = VideoAdapter()..onSample(poor);
    feed(adapter, List.filled(5, poor));
    adapter.reset();
    expect(adapter.level, VideoLevel.full);
    expect(feed(adapter, [poor]), isEmpty, reason: 'the streak starts over');
  });

  group('QualitySample.uploadAt', () {
    const full = VideoLevel.full;
    test('judges the upload from send loss, round trip and bandwidth', () {
      expect(const QualitySample().uploadAt(full), isNull);
      expect(
        const QualitySample(sendLoss: 0, sendBitrate: 2000000).uploadAt(full),
        good,
      );
      expect(const QualitySample(sendLoss: 0.05).uploadAt(full), fair);
      expect(const QualitySample(sendLoss: 0.2).uploadAt(full), poor);
      expect(const QualitySample(sendBitrate: 80000).uploadAt(full), poor);
      expect(
        const QualitySample(roundTrip: Duration(milliseconds: 700))
            .uploadAt(full),
        poor,
      );
      expect(
        const QualitySample(packetLoss: 0.5).uploadAt(full),
        isNull,
        reason: 'what this device receives is the other side\'s upload',
      );
    });

    test('a bandwidth estimate held down by lowered video is not weak', () {
      expect(
        const QualitySample(
          sendLoss: 0,
          sendBitrate: 160000,
        ).uploadAt(VideoLevel.low),
        good,
        reason: 'low video sends about 150 kbit/s, so the estimate is near it',
      );
      expect(
        const QualitySample(
          sendLoss: 0,
          sendBitrate: 40000,
        ).uploadAt(VideoLevel.paused),
        good,
        reason: 'with video paused only voice is sent',
      );
    });
  });
}
