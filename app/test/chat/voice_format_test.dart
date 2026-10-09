import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/voice/voice_format.dart';

String _ascii(Uint8List bytes, int offset, int length) =>
    String.fromCharCodes(bytes.sublist(offset, offset + length));

/// A PCM WAV file: the header, then [dataBytes] zero bytes of samples.
Uint8List _wav({
  int sampleRate = 16000,
  int channels = 1,
  int bits = 16,
  int dataBytes = 64,
}) {
  final header = wavHeader(
    sampleRate: sampleRate,
    channels: channels,
    bitsPerSample: bits,
    dataBytes: dataBytes,
  );
  return Uint8List.fromList([...header, ...List.filled(dataBytes, 0)]);
}

/// An MP4 file starting with an `ftyp` box with [brand] as its major brand.
Uint8List _mp4(String brand) => Uint8List.fromList([
  0, 0, 0, 0x18, //
  ...'ftyp'.codeUnits,
  ...brand.codeUnits,
  0, 0, 0, 0,
  ...'isom'.codeUnits,
]);

void main() {
  group('wavHeader', () {
    test('lays out the 44 bytes of a PCM WAV file', () {
      final bytes = wavHeader(
        sampleRate: 16000,
        channels: 1,
        bitsPerSample: 16,
        dataBytes: 1000,
      );
      final view = ByteData.sublistView(bytes);

      expect(bytes.length, 44);
      expect(_ascii(bytes, 0, 4), 'RIFF');
      expect(view.getUint32(4, Endian.little), 36 + 1000, reason: 'RIFF size');
      expect(_ascii(bytes, 8, 4), 'WAVE');
      expect(_ascii(bytes, 12, 4), 'fmt ');
      expect(view.getUint32(16, Endian.little), 16, reason: 'fmt size');
      expect(view.getUint16(20, Endian.little), 1, reason: 'PCM format');
      expect(view.getUint16(22, Endian.little), 1, reason: 'channels');
      expect(view.getUint32(24, Endian.little), 16000, reason: 'sample rate');
      expect(view.getUint32(28, Endian.little), 32000, reason: 'byte rate');
      expect(view.getUint16(32, Endian.little), 2, reason: 'block align');
      expect(view.getUint16(34, Endian.little), 16, reason: 'bits');
      expect(_ascii(bytes, 36, 4), 'data');
      expect(view.getUint32(40, Endian.little), 1000, reason: 'data size');
    });

    test('follows the sample rate, channels and bits given', () {
      final bytes = wavHeader(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 24,
        dataBytes: 6,
      );
      final view = ByteData.sublistView(bytes);

      expect(view.getUint16(22, Endian.little), 2);
      expect(view.getUint32(24, Endian.little), 48000);
      expect(view.getUint32(28, Endian.little), 48000 * 2 * 3);
      expect(view.getUint16(32, Endian.little), 6);
      expect(view.getUint16(34, Endian.little), 24);
    });

    test('an empty data chunk gives RIFF size 36', () {
      final view = ByteData.sublistView(
        wavHeader(
          sampleRate: 8000,
          channels: 1,
          bitsPerSample: 16,
          dataBytes: 0,
        ),
      );
      expect(view.getUint32(4, Endian.little), 36);
      expect(view.getUint32(40, Endian.little), 0);
    });

    test('refuses a format it cannot describe', () {
      expect(
        () => wavHeader(
          sampleRate: 0,
          channels: 1,
          bitsPerSample: 16,
          dataBytes: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => wavHeader(
          sampleRate: 16000,
          channels: 1,
          bitsPerSample: 12,
          dataBytes: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => wavHeader(
          sampleRate: 16000,
          channels: 1,
          bitsPerSample: 16,
          dataBytes: -1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('the voice allowlist and the audio decision', () {
    test('audio/mp4 and audio/wav are voice notes', () {
      expect(isVoiceMime('audio/mp4'), isTrue);
      expect(isVoiceMime('audio/wav'), isTrue);
    });

    test('parameters and case are ignored', () {
      expect(isVoiceMime('audio/mp4;codecs=mp4a.40.2'), isTrue);
      expect(isVoiceMime('audio/wav; codecs=1'), isTrue);
      expect(isVoiceMime('AUDIO/MP4 '), isTrue);
      expect(baseMime(' Audio/MP4 ; codecs="mp4a.40.2"'), 'audio/mp4');
    });

    test('other audio is audio but not a voice note', () {
      for (final mime in [
        'audio/mpeg',
        'audio/webm;codecs=opus',
        'audio/ogg',
        'audio/aac',
        'audio/mp4a-latm',
      ]) {
        expect(isAudioMime(mime), isTrue, reason: mime);
        expect(isVoiceMime(mime), isFalse, reason: mime);
      }
    });

    test('non-audio types are not audio at all', () {
      for (final mime in ['video/mp4', 'image/png', 'application/pdf', '']) {
        expect(isAudioMime(mime), isFalse, reason: mime);
        expect(isVoiceMime(mime), isFalse, reason: mime);
      }
    });

    test('an audio offer that is not a voice note is declined', () {
      expect(voiceOfferRefused(mime: 'audio/mpeg', size: 1000), isTrue);
      expect(
        voiceOfferRefused(mime: 'audio/webm;codecs=opus', size: 1000),
        isTrue,
      );
    });

    test('a voice note offer within the cap is not declined', () {
      expect(voiceOfferRefused(mime: 'audio/mp4', size: 1200000), isFalse);
      expect(
        voiceOfferRefused(mime: 'audio/wav;codecs=1', size: 9600044),
        isFalse,
      );
    });

    test('a voice note over the cap of its type is declined', () {
      // AAC is capped at 2 MiB, and the WAV fallback at its 300-second size.
      expect(
        voiceOfferRefused(mime: 'audio/mp4', size: maxVoiceAacBytes),
        isFalse,
      );
      expect(
        voiceOfferRefused(mime: 'audio/mp4', size: maxVoiceAacBytes + 1),
        isTrue,
      );
      expect(
        voiceOfferRefused(mime: 'audio/mp4', size: maxVoiceBytes),
        isTrue,
      );
      expect(
        voiceOfferRefused(mime: 'audio/wav', size: maxVoiceWavBytes),
        isFalse,
      );
      expect(
        voiceOfferRefused(mime: 'audio/wav', size: maxVoiceWavBytes + 1),
        isTrue,
      );
    });

    test('other types are judged elsewhere', () {
      expect(voiceOfferRefused(mime: 'application/pdf', size: 10), isFalse);
      expect(voiceOfferRefused(mime: 'video/mp4', size: 10), isFalse);
    });
  });

  group('the voice limits by type', () {
    test('AAC is capped at 2 MiB and WAV at its 300-second size', () {
      expect(voiceCapBytes('audio/mp4;codecs=mp4a.40.2'), 2 * 1024 * 1024);
      expect(voiceCapBytes('audio/wav'), 9600044);
      expect(voiceCapBytes('audio/mpeg'), 0);
    });

    test('no type is capped above the 10 MiB offer limit', () {
      expect(voiceCapBytes('audio/mp4'), lessThanOrEqualTo(maxVoiceBytes));
      expect(voiceCapBytes('audio/wav'), lessThanOrEqualTo(maxVoiceBytes));
    });

    test('the name must end in the extension of its type', () {
      expect(voiceNameMatches('audio/mp4', 'voice-1700000000000.m4a'), isTrue);
      expect(voiceNameMatches('audio/mp4', 'Voice.M4A'), isTrue);
      expect(voiceNameMatches('audio/mp4', 'song.mp3'), isFalse);
      expect(voiceNameMatches('audio/mp4', 'song.m4a.exe'), isFalse);
      expect(voiceNameMatches('audio/wav', 'note.WAV'), isTrue);
      expect(voiceNameMatches('audio/wav', 'note.m4a'), isFalse);
      expect(voiceNameMatches('audio/mpeg', 'note.mp3'), isFalse);
    });

    test('a WAV format is mono, 16 bits, 8000 to 48000 Hz', () {
      bool ok(int rate, int channels, int bits) => isVoiceWavFormat(
        sampleRate: rate,
        channels: channels,
        bitsPerSample: bits,
      );
      expect(ok(16000, 1, 16), isTrue);
      expect(ok(8000, 1, 16), isTrue);
      expect(ok(48000, 1, 16), isTrue);
      expect(ok(7999, 1, 16), isFalse);
      expect(ok(48001, 1, 16), isFalse);
      expect(ok(16000, 2, 16), isFalse);
      expect(ok(16000, 1, 8), isFalse);
    });
  });

  group('limits', () {
    test('a voice note is at most 300 seconds', () {
      expect(maxVoiceSeconds, 300);
    });

    test('an offer is at most 10 MiB', () {
      expect(maxVoiceBytes, 10 * 1024 * 1024);
    });

    test('300 seconds of the WAV fallback fits, with its header', () {
      expect(voiceWavBytes(300), 9600044);
      expect(voiceWavBytes(300), lessThanOrEqualTo(maxVoiceBytes));
    });

    test('300 seconds of AAC at 32 kbps fits', () {
      const aacBytes = maxVoiceSeconds * voiceAacBitRate ~/ 8;
      expect(aacBytes, 1200000);
      expect(aacBytes, lessThanOrEqualTo(maxVoiceBytes));
    });

    test('a note must have bytes and fit the cap', () {
      expect(voiceNoteFits(0), isFalse);
      expect(voiceNoteFits(1), isTrue);
      expect(voiceNoteFits(maxVoiceBytes), isTrue);
      expect(voiceNoteFits(maxVoiceBytes + 1), isFalse);
    });
  });

  group('web recordings', () {
    test('codec parameters are stripped from the blob type', () {
      expect(webRecordingMime('audio/mp4;codecs=mp4a.40.2'), 'audio/mp4');
      expect(webRecordingMime('audio/mp4;codecs=mp4a'), 'audio/mp4');
      expect(webRecordingMime('Audio/MP4; codecs=mp4a'), 'audio/mp4');
    });

    test('a blank type becomes the type the AAC route asked for', () {
      expect(webRecordingMime(''), 'audio/mp4');
      expect(webRecordingMime('  '), 'audio/mp4');
      expect(webRecordingMime('', fallback: 'audio/wav'), 'audio/wav');
    });

    test('a type that is not a voice note stays one after stripping', () {
      final mime = webRecordingMime('audio/webm;codecs=opus');
      expect(mime, 'audio/webm');
      expect(isVoiceMime(mime), isFalse);
    });

    test('the file name carries the extension', () {
      expect(voiceFileName(1700000000000, 'm4a'), 'voice-1700000000000.m4a');
      expect(voiceFileName(1700000000000, 'wav'), 'voice-1700000000000.wav');
    });
  });

  group('voiceBytesLookRight', () {
    test('a PCM WAV of the fallback format is right', () {
      expect(voiceBytesLookRight('audio/wav', _wav()), isTrue);
      expect(voiceBytesLookRight('audio/wav', _wav(sampleRate: 8000)), isTrue);
      expect(voiceBytesLookRight('audio/wav', _wav(sampleRate: 48000)), isTrue);
    });

    test('a WAV of the wrong format is damaged', () {
      expect(voiceBytesLookRight('audio/wav', _wav(bits: 8)), isFalse);
      expect(voiceBytesLookRight('audio/wav', _wav(channels: 2)), isFalse);
      expect(
        voiceBytesLookRight('audio/wav', _wav(sampleRate: 96000)),
        isFalse,
      );
      expect(voiceBytesLookRight('audio/wav', _wav(sampleRate: 4000)), isFalse);
    });

    test('a WAV without a data chunk is damaged', () {
      final header = wavHeader(
        sampleRate: 16000,
        channels: 1,
        bitsPerSample: 16,
        dataBytes: 0,
      );
      // The fmt chunk alone, with no data chunk after it.
      expect(
        voiceBytesLookRight(
          'audio/wav',
          Uint8List.fromList(header.sublist(0, 36)),
        ),
        isFalse,
      );
    });

    test('a RIFF file that is not a WAVE file is damaged', () {
      final bytes = _wav();
      bytes.setRange(8, 12, 'AVI '.codeUnits);
      expect(voiceBytesLookRight('audio/wav', bytes), isFalse);
    });

    test('a WAV with an odd-sized chunk before fmt is still read', () {
      final pad = Uint8List.fromList([
        ...'LIST'.codeUnits,
        3, 0, 0, 0,
        1, 2, 3, 0, // three bytes and the pad byte
      ]);
      final wav = _wav();
      final bytes = Uint8List.fromList([
        ...wav.sublist(0, 12),
        ...pad,
        ...wav.sublist(12),
      ]);
      expect(voiceBytesLookRight('audio/wav', bytes), isTrue);
    });

    test('an MP4 with a known major brand is right', () {
      for (final brand in ['M4A ', 'mp42', 'isom']) {
        expect(
          voiceBytesLookRight('audio/mp4', _mp4(brand)),
          isTrue,
          reason: brand,
        );
      }
    });

    test('an MP4 with another brand, or no ftyp box, is damaged', () {
      expect(voiceBytesLookRight('audio/mp4', _mp4('mp41')), isFalse);
      expect(voiceBytesLookRight('audio/mp4', _wav()), isFalse);
      expect(voiceBytesLookRight('audio/mp4', Uint8List(4)), isFalse);
    });

    test('a mime that is not a voice note has no right bytes', () {
      expect(voiceBytesLookRight('audio/mpeg', _mp4('M4A ')), isFalse);
    });
  });

  group('silence and time', () {
    test('a recording that never rose above the silent level is silent', () {
      expect(isSilentPeak(double.negativeInfinity), isTrue);
      expect(isSilentPeak(-160), isTrue);
      expect(isSilentPeak(-60.5), isTrue);
      expect(isSilentPeak(double.nan), isTrue);
    });

    test('a recording with speech in it is not silent', () {
      expect(isSilentPeak(-60), isFalse);
      expect(isSilentPeak(-20), isFalse);
      expect(isSilentPeak(0), isFalse);
    });

    test('a length is shown as minutes and seconds', () {
      expect(formatVoiceDuration(Duration.zero), '0:00');
      expect(formatVoiceDuration(const Duration(seconds: 9)), '0:09');
      expect(formatVoiceDuration(const Duration(seconds: 65)), '1:05');
      expect(formatVoiceDuration(const Duration(seconds: 300)), '5:00');
      expect(formatVoiceDuration(const Duration(milliseconds: -5)), '0:00');
    });
  });
}
