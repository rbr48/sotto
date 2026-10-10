import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Resizes [bytes] to a small avatar thumbnail (max [maxDimension] x [maxDimension] px,
/// PNG format, typically 4-12 KB) so it fits safely within cryptographic envelopes
/// and relay limits.
Future<Uint8List> resizeAvatarImage(
  Uint8List bytes, {
  int maxDimension = 128,
}) async {
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: maxDimension,
      targetHeight: maxDimension,
    );
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData != null && byteData.lengthInBytes > 0) {
          return byteData.buffer.asUint8List();
        }
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {}

  // Fallback: if already small enough (under 16 KB), return raw bytes.
  if (bytes.length <= 16 * 1024) {
    return bytes;
  }
  throw ArgumentError(
    'Avatar image is too large and could not be downsampled.',
  );
}

/// Helper to convert resized image bytes to a base64 data URL string.
String avatarBytesToDataUrl(Uint8List bytes) {
  return 'data:image/png;base64,${base64Encode(bytes)}';
}
