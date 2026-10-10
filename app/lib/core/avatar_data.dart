import 'dart:convert';
import 'dart:typed_data';

/// The image types a profile picture may have.
enum AvatarType {
  jpeg('image/jpeg'),
  png('image/png');

  const AvatarType(this.mime);

  /// The MIME type in the data URI.
  final String mime;

  /// `data:<mime>;base64,`
  String get prefix => 'data:$mime;base64,';
}

/// A checked profile picture: a JPEG or PNG data URI whose bytes are the type
/// it claims and whose header gives a size of at most [AvatarData.maxSide].
///
/// Pictures are made by this app at most [maxCreatedLength] characters long
/// (see `avatar_helper.dart`), sent only when at most [maxSharedLength], and
/// anything else that arrives is dropped: received pictures are never trusted
/// to be small or well formed.
class AvatarData {
  const AvatarData._(this.type, this.bytes, this.width, this.height);

  /// The longest data URI this app makes for a picture.
  static const int maxCreatedLength = 16 * 1024;

  /// The longest data URI that is sent to, or accepted from, anyone else.
  static const int maxSharedLength = 24 * 1024;

  /// The largest width or height a picture may claim.
  static const int maxSide = 512;

  final AvatarType type;
  final Uint8List bytes;
  final int width;
  final int height;

  static const _jpegMagic = [0xFF, 0xD8, 0xFF];
  static const _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  /// The checked picture in [uri], or null when it is missing, longer than
  /// [maxLength], not a base64 JPEG/PNG data URI, not the type it claims, or
  /// larger than [maxSide] × [maxSide] pixels.
  static AvatarData? parse(String? uri, {int maxLength = maxSharedLength}) {
    if (uri == null || uri.isEmpty || uri.length > maxLength) return null;
    for (final type in AvatarType.values) {
      if (!uri.startsWith(type.prefix)) continue;
      final Uint8List bytes;
      try {
        bytes = base64.decode(uri.substring(type.prefix.length));
      } on FormatException {
        return null;
      }
      final size = switch (type) {
        AvatarType.jpeg => jpegSize(bytes),
        AvatarType.png => pngSize(bytes),
      };
      if (size == null) return null;
      final (width, height) = size;
      if (width < 1 || height < 1 || width > maxSide || height > maxSide) {
        return null;
      }
      return AvatarData._(type, bytes, width, height);
    }
    return null;
  }

  /// Whether [uri] is a picture [parse] accepts.
  static bool isValid(String? uri, {int maxLength = maxSharedLength}) =>
      parse(uri, maxLength: maxLength) != null;

  /// [uri] when it is a picture [parse] accepts, otherwise null.
  static String? sanitize(String? uri, {int maxLength = maxSharedLength}) =>
      isValid(uri, maxLength: maxLength) ? uri : null;

  /// Width and height from a PNG's header (its first chunk, IHDR), or null
  /// if [bytes] is not a PNG.
  static (int, int)? pngSize(Uint8List bytes) {
    if (bytes.length < 33 || !_startsWith(bytes, _pngMagic)) return null;
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(8) != 13 ||
        String.fromCharCodes(bytes, 12, 16) != 'IHDR') {
      return null;
    }
    return (data.getUint32(16), data.getUint32(20));
  }

  /// Width and height from a JPEG's frame header (SOFn), or null if [bytes]
  /// is not a JPEG or has no frame header before its image data.
  static (int, int)? jpegSize(Uint8List bytes) {
    if (!_startsWith(bytes, _jpegMagic)) return null;
    var i = 2;
    while (i < bytes.length) {
      if (bytes[i] != 0xFF) return null;
      // Fill bytes may come before a marker.
      while (i < bytes.length && bytes[i] == 0xFF) {
        i++;
      }
      if (i >= bytes.length) return null;
      final marker = bytes[i++];
      // Markers without a length.
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
      // Image data or the end of the image, and still no frame header.
      if (marker == 0xDA || marker == 0xD9) return null;
      if (i + 2 > bytes.length) return null;
      final length = (bytes[i] << 8) | bytes[i + 1];
      if (length < 2 || i + length > bytes.length) return null;
      final isFrame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isFrame) {
        if (length < 7) return null;
        final height = (bytes[i + 3] << 8) | bytes[i + 4];
        final width = (bytes[i + 5] << 8) | bytes[i + 6];
        return (width, height);
      }
      i += length;
    }
    return null;
  }

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }
}
