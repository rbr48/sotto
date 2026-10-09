import 'dart:typed_data';

/// The image types whose metadata [ImageMetadata] removes.
enum ImageKind { jpeg, png }

/// Removes metadata from an image before it is shared: location and camera
/// details (EXIF, XMP, IPTC), comments, text chunks, and anything after the end
/// of the image. The pixels, and the structure that draws them, are copied byte
/// for byte.
///
/// The type comes from the bytes, never from the MIME type. An image that is
/// malformed throws [FormatException].
abstract final class ImageMetadata {
  static const _pngSignature = [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ];

  /// PNG chunks that carry metadata: text, compressed text, international text,
  /// the last modification time, and EXIF.
  static const _pngMetadataTypes = {'tEXt', 'zTXt', 'iTXt', 'tIME', 'eXIf'};

  /// The type of [bytes], from its first bytes, or null if it is neither JPEG
  /// nor PNG.
  static ImageKind? kindOf(Uint8List bytes) {
    if (_startsWith(bytes, const [0xFF, 0xD8, 0xFF])) return ImageKind.jpeg;
    if (_startsWith(bytes, _pngSignature)) return ImageKind.png;
    return null;
  }

  /// [bytes] ready to share, without metadata.
  ///
  /// A file that is not an image is returned unchanged. The exception is a
  /// file whose [mime] says it is an image: that is refused, since this app
  /// cannot clean that type.
  static Uint8List clean(Uint8List bytes, String mime) {
    final kind = kindOf(bytes);
    if (kind == null) {
      if (mime.trim().toLowerCase().startsWith('image/')) {
        throw ArgumentError('Image type not supported for sharing');
      }
      return bytes;
    }
    return switch (kind) {
      ImageKind.jpeg => stripJpeg(bytes),
      ImageKind.png => stripPng(bytes),
    };
  }

  /// [bytes], a JPEG, without its APPn and COM segments. The exceptions are
  /// the segments that describe colour: JFIF, the ICC profile and Adobe. The
  /// scan data is kept, and nothing after the end-of-image marker is.
  static Uint8List stripJpeg(Uint8List bytes) {
    if (!_startsWith(bytes, const [0xFF, 0xD8])) {
      throw const FormatException('Not a JPEG');
    }
    final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
    var pos = 2;
    while (true) {
      if (pos >= bytes.length || bytes[pos] != 0xFF) {
        throw const FormatException('JPEG marker expected');
      }
      // Fill bytes (more 0xFF bytes) may come before the marker code.
      var code = pos + 1;
      while (code < bytes.length && bytes[code] == 0xFF) {
        code++;
      }
      if (code >= bytes.length || bytes[code] == 0x00) {
        throw const FormatException('JPEG marker invalid');
      }
      final marker = bytes[code];
      pos = code + 1;
      if (marker == 0xD9) {
        // End of image: the last thing kept.
        out.add(const [0xFF, 0xD9]);
        return out.takeBytes();
      }
      if (marker == 0x01 ||
          marker == 0xD8 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        // Markers with no length field.
        out.add([0xFF, marker]);
        continue;
      }
      if (pos + 2 > bytes.length) {
        throw const FormatException('JPEG segment truncated');
      }
      final length = (bytes[pos] << 8) | bytes[pos + 1];
      final end = pos + length;
      if (length < 2 || end > bytes.length) {
        throw const FormatException('JPEG segment length invalid');
      }
      if (_keepsJpegSegment(marker, bytes, pos + 2, end)) {
        out
          ..add([0xFF, marker])
          ..add(bytes.sublist(pos, end));
      }
      pos = end;
      if (marker == 0xDA) {
        // Start of scan: entropy-coded data follows the header, up to the next
        // marker. A progressive file has several scans.
        final next = _scanEnd(bytes, pos);
        out.add(bytes.sublist(pos, next));
        pos = next;
      }
    }
  }

  /// [bytes], a PNG, without its text and EXIF chunks, and without anything
  /// after the IEND chunk. Every other chunk is copied as it is, CRC included.
  static Uint8List stripPng(Uint8List bytes) {
    if (!_startsWith(bytes, _pngSignature)) {
      throw const FormatException('Not a PNG');
    }
    final out = BytesBuilder(copy: false)..add(_pngSignature);
    final view = ByteData.sublistView(bytes);
    var pos = _pngSignature.length;
    while (true) {
      if (pos + 12 > bytes.length) {
        throw const FormatException('PNG chunk truncated');
      }
      final length = view.getUint32(pos, Endian.big);
      final end = pos + 12 + length;
      if (end > bytes.length) {
        throw const FormatException('PNG chunk past end');
      }
      final type = String.fromCharCodes(bytes.sublist(pos + 4, pos + 8));
      if (!_pngMetadataTypes.contains(type)) {
        out.add(bytes.sublist(pos, end));
      }
      pos = end;
      if (type == 'IEND') return out.takeBytes();
    }
  }

  /// Whether the JPEG segment with [marker], whose payload is the bytes from
  /// [start] to [end], is kept.
  static bool _keepsJpegSegment(
    int marker,
    Uint8List bytes,
    int start,
    int end,
  ) {
    if (marker == 0xFE) return false; // COM: a comment.
    if (marker < 0xE0 || marker > 0xEF) return true; // Not an APPn segment.
    final identifier = switch (marker) {
      0xE0 => 'JFIF\u0000', // APP0: JFIF, which gives the colour and density.
      0xE2 => 'ICC_PROFILE\u0000', // APP2: the colour profile.
      0xEE => 'Adobe', // APP14: the Adobe colour transform.
      _ => null,
    };
    return identifier != null &&
        _startsWithText(bytes, start, end, identifier);
  }

  /// The index of the marker that ends the entropy-coded data that starts at
  /// [start]. Stuffed zero bytes, restart markers and fill bytes are part of
  /// the data, not markers.
  static int _scanEnd(Uint8List bytes, int start) {
    var i = start;
    while (true) {
      final ff = bytes.indexOf(0xFF, i);
      if (ff < 0 || ff + 1 >= bytes.length) {
        throw const FormatException('JPEG scan has no end');
      }
      final next = bytes[ff + 1];
      if (next == 0x00 || (next >= 0xD0 && next <= 0xD7)) {
        i = ff + 2;
      } else if (next == 0xFF) {
        // A fill byte: the marker is the last 0xFF of the run.
        i = ff + 1;
      } else {
        return ff;
      }
    }
  }

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static bool _startsWithText(
    Uint8List bytes,
    int start,
    int end,
    String text,
  ) {
    if (end - start < text.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (bytes[start + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }
}
