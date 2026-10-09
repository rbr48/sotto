import 'dart:typed_data';

/// Voice notes: what a recording is, what the receiving side accepts, and the
/// limits both sides keep (`docs/PROTOCOL.md`, "Voice notes").
///
/// Everything here is pure, so the rules can be tested without a device.

/// The longest voice note, in seconds. The size limits below follow from it.
const int maxVoiceSeconds = 300;

/// The largest voice offer accepted, in bytes (10 MiB). Each type has a lower
/// cap, see [voiceCapBytes].
const int maxVoiceBytes = 10 * 1024 * 1024;

/// The largest AAC voice note accepted, in bytes (2 MiB). 300 seconds of AAC
/// at 32 kbps is about 1.2 MB, so it fits.
const int maxVoiceAacBytes = 2 * 1024 * 1024;

/// The AAC-LC route: mono, 16 kHz, 32 kbps.
const int voiceSampleRate = 16000;
const int voiceChannels = 1;
const int voiceBitsPerSample = 16;
const int voiceAacBitRate = 32000;

/// The largest WAV voice note accepted: 300 seconds of the WAV fallback with
/// its 44-byte header, 9,600,044 bytes.
final int maxVoiceWavBytes = voiceWavBytes(maxVoiceSeconds);

/// The `kind` of a file offer that is a voice note. An offer without a kind,
/// or with any other one, is a plain file, whatever its MIME type.
const String voiceOfferKind = 'voice';

/// The MIME types of voice notes. Any other `audio/*` offer is not a voice
/// note, and a plain file is judged as a file.
const List<String> voiceMimes = ['audio/mp4', 'audio/wav'];

/// [mime] lower-cased, with its parameters removed and the ends trimmed:
/// `audio/mp4;codecs=mp4a.40.2` becomes `audio/mp4`.
String baseMime(String mime) {
  final semi = mime.indexOf(';');
  final base = semi < 0 ? mime : mime.substring(0, semi);
  return base.trim().toLowerCase();
}

/// Whether [mime] is an audio type at all.
bool isAudioMime(String mime) => baseMime(mime).startsWith('audio/');

/// Whether [mime] is one of the voice note types.
bool isVoiceMime(String mime) => voiceMimes.contains(baseMime(mime));

/// The size limit of a voice note of [mime]: 2 MiB for AAC and 9,600,044 bytes
/// for WAV. Zero for a type that is not a voice note.
int voiceCapBytes(String mime) => switch (baseMime(mime)) {
  'audio/mp4' => maxVoiceAacBytes,
  'audio/wav' => maxVoiceWavBytes,
  _ => 0,
};

/// Whether an offer of [mime] and [size] that says it is a voice note is
/// refused for its audio type: audio that is not a voice note, or a voice note
/// over its type's cap. Other types are not judged here, and the name rule
/// ([voiceNameMatches]) refuses them on the voice path.
bool voiceOfferRefused({required String mime, required int size}) =>
    isAudioMime(mime) && (!isVoiceMime(mime) || size > voiceCapBytes(mime));

/// Whether the [name] of a voice offer of [mime] ends in the extension that
/// type needs: `.m4a` for audio/mp4 and `.wav` for audio/wav.
bool voiceNameMatches(String mime, String name) {
  final lower = name.toLowerCase();
  return switch (baseMime(mime)) {
    'audio/mp4' => lower.endsWith('.m4a'),
    'audio/wav' => lower.endsWith('.wav'),
    _ => false,
  };
}

/// Whether a PCM WAV format is one a voice note may have: mono, 16 bits and
/// 8000 to 48000 Hz. The recorder checks the format the platform captures
/// against this, and the receiver checks the file it gets.
bool isVoiceWavFormat({
  required int sampleRate,
  required int channels,
  required int bitsPerSample,
}) =>
    channels == voiceChannels &&
    bitsPerSample == voiceBitsPerSample &&
    sampleRate >= 8000 &&
    sampleRate <= 48000;

/// Whether a voice note of [bytes] is within the size limit (and not empty).
bool voiceNoteFits(int bytes) => bytes > 0 && bytes <= maxVoiceBytes;

/// The MIME type a web recording is sent as: its codec parameters stripped
/// (`audio/mp4;codecs=mp4a.40.2` becomes `audio/mp4`). A blank type becomes
/// [fallback], the type the AAC route asked for.
String webRecordingMime(String blobType, {String fallback = 'audio/mp4'}) {
  final base = baseMime(blobType);
  return base.isEmpty ? fallback : base;
}

/// The name a voice note is offered under: `voice-<timestamp>.m4a` or `.wav`.
String voiceFileName(int timestampMs, String extension) =>
    'voice-$timestampMs.$extension';

/// The size of a WAV voice note of [seconds] in the fallback format, header
/// included.
int voiceWavBytes(int seconds) =>
    44 + seconds * voiceSampleRate * voiceChannels * voiceBitsPerSample ~/ 8;

/// The 44-byte RIFF header of a PCM WAV file holding [dataBytes] bytes of
/// samples, in little-endian order.
Uint8List wavHeader({
  required int sampleRate,
  required int channels,
  required int bitsPerSample,
  required int dataBytes,
}) {
  final blockAlign = channels * bitsPerSample ~/ 8;
  final byteRate = sampleRate * blockAlign;
  if (sampleRate <= 0 ||
      channels <= 0 ||
      bitsPerSample <= 0 ||
      bitsPerSample % 8 != 0 ||
      blockAlign <= 0 ||
      byteRate > 0xFFFFFFFF ||
      dataBytes < 0 ||
      dataBytes > 0xFFFFFFFF - 36) {
    throw ArgumentError('not a WAV format this app writes');
  }
  final header = ByteData(44);
  _writeAscii(header, 0, 'RIFF');
  header.setUint32(4, 36 + dataBytes, Endian.little);
  _writeAscii(header, 8, 'WAVE');
  _writeAscii(header, 12, 'fmt ');
  header.setUint32(16, 16, Endian.little); // PCM fmt chunk size
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  _writeAscii(header, 36, 'data');
  header.setUint32(40, dataBytes, Endian.little);
  return header.buffer.asUint8List();
}

void _writeAscii(ByteData data, int offset, String text) {
  for (var i = 0; i < text.length; i++) {
    data.setUint8(offset + i, text.codeUnitAt(i));
  }
}

/// Whether [bytes] look like a finished voice note of [mime]. A file that
/// does not is damaged. An MP4 needs an `ftyp` box with the major brand `M4A `,
/// `mp42` or `isom`. A WAV needs a RIFF/WAVE file with a PCM `fmt ` chunk
/// (1 channel, 16 bits, 8000 to 48000 Hz) before a `data` chunk.
bool voiceBytesLookRight(String mime, Uint8List bytes) =>
    switch (baseMime(mime)) {
      'audio/mp4' => _looksLikeMp4(bytes),
      'audio/wav' => _looksLikeWav(bytes),
      _ => false,
    };

bool _looksLikeMp4(Uint8List bytes) {
  if (bytes.length < 12 || !_hasAscii(bytes, 4, 'ftyp')) return false;
  return const ['M4A ', 'mp42', 'isom'].any((b) => _hasAscii(bytes, 8, b));
}

bool _looksLikeWav(Uint8List bytes) {
  if (bytes.length < 12 ||
      !_hasAscii(bytes, 0, 'RIFF') ||
      !_hasAscii(bytes, 8, 'WAVE')) {
    return false;
  }
  final view = ByteData.sublistView(bytes);
  var formatOk = false;
  var pos = 12;
  while (pos + 8 <= bytes.length) {
    final size = view.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (_hasAscii(bytes, pos, 'fmt ')) {
      if (size < 16 || body + 16 > bytes.length) return false;
      final format = view.getUint16(body, Endian.little);
      final channels = view.getUint16(body + 2, Endian.little);
      final rate = view.getUint32(body + 4, Endian.little);
      final bits = view.getUint16(body + 14, Endian.little);
      formatOk =
          format == 1 &&
          isVoiceWavFormat(
            sampleRate: rate,
            channels: channels,
            bitsPerSample: bits,
          );
      if (!formatOk) return false;
    } else if (_hasAscii(bytes, pos, 'data')) {
      return formatOk;
    }
    // Chunks are word aligned: an odd size has one pad byte.
    pos = body + size + (size.isOdd ? 1 : 0);
  }
  return false;
}

bool _hasAscii(Uint8List bytes, int offset, String text) {
  if (offset < 0 || offset + text.length > bytes.length) return false;
  for (var i = 0; i < text.length; i++) {
    if (bytes[offset + i] != text.codeUnitAt(i)) return false;
  }
  return true;
}

/// The peak level (dBFS) under which a Windows recording counts as silent.
const double voiceSilentPeakDb = -60;

/// Whether a recording whose loudest reading was [peakDb] stayed silent. A
/// silent recording means the microphone is blocked, so it is never sent.
bool isSilentPeak(double peakDb) => peakDb.isNaN || peakDb < voiceSilentPeakDb;

/// A recording's length as `m:ss`.
String formatVoiceDuration(Duration duration) {
  final total = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  final minutes = total ~/ 60;
  final seconds = (total % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
