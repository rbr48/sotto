import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'avatar_data.dart';

export 'avatar_data.dart';

/// Why a picture could not be made into a profile picture.
enum AvatarError {
  /// The file is larger than [maxAvatarInputBytes].
  inputTooLarge,

  /// The file is not an image this device can decode.
  unreadable,

  /// Even the smallest thumbnail is over [AvatarData.maxCreatedLength].
  tooLarge,
}

class AvatarException implements Exception {
  const AvatarException(this.error);
  final AvatarError error;

  @override
  String toString() => 'AvatarException(${error.name})';
}

/// The largest file accepted as a source for a profile picture.
const int maxAvatarInputBytes = 10 * 1024 * 1024;

/// The thumbnails tried, in order: side in pixels, and how many low bits of
/// each colour channel are dropped (which helps PNG compress photos).
///
/// The pictures are PNG because Flutter has no JPEG encoder and no encoder
/// package fits the app's dependencies. A 32 × 32 RGBA PNG is at most about
/// 4.2 KB, 5.6 KB as base64, so the last step always fits.
const List<(int, int)> _attempts = [
  (64, 0),
  (64, 2),
  (48, 2),
  (48, 3),
  (32, 3),
];

/// Makes a square profile picture from the image file [bytes]: the centre
/// square, scaled down, re-encoded from its pixels as a PNG (so nothing of
/// the file's metadata, such as EXIF location, survives), as a data URI of at
/// most [maxLength] characters.
///
/// Throws [AvatarException] when the file is too large, cannot be decoded,
/// or cannot be made small enough.
Future<String> makeAvatarDataUri(
  Uint8List bytes, {
  int maxLength = AvatarData.maxCreatedLength,
}) async {
  if (bytes.length > maxAvatarInputBytes) {
    throw const AvatarException(AvatarError.inputTooLarge);
  }
  final largest = _attempts.first.$1;
  final ui.Image decoded;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    // Decoded straight to about the size needed: the shorter side becomes
    // [largest] and the aspect ratio is kept, so nothing is squashed.
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) => width <= height
          ? ui.TargetImageSize(width: largest)
          : ui.TargetImageSize(height: largest),
    );
    try {
      decoded = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } catch (_) {
    throw const AvatarException(AvatarError.unreadable);
  }
  try {
    for (final (side, droppedBits) in _attempts) {
      final png = await _squarePng(decoded, side, droppedBits);
      if (png == null) throw const AvatarException(AvatarError.unreadable);
      final uri = '${AvatarType.png.prefix}${base64.encode(png)}';
      if (uri.length <= maxLength) return uri;
    }
  } finally {
    decoded.dispose();
  }
  throw const AvatarException(AvatarError.tooLarge);
}

/// The centre square of [image], scaled to [side] × [side], as a PNG with
/// only its critical chunks.
Future<Uint8List?> _squarePng(ui.Image image, int side, int droppedBits) async {
  final crop = image.width < image.height ? image.width : image.height;
  final source = ui.Rect.fromLTWH(
    (image.width - crop) / 2,
    (image.height - crop) / 2,
    crop.toDouble(),
    crop.toDouble(),
  );
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    source,
    ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  var square = await picture.toImage(side, side);
  picture.dispose();
  try {
    if (droppedBits > 0) {
      final pixels = await square.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (pixels == null) return null;
      final rgba = pixels.buffer.asUint8List(
        pixels.offsetInBytes,
        pixels.lengthInBytes,
      );
      _dropLowBits(rgba, droppedBits);
      final reduced = await _fromPixels(rgba, side);
      square.dispose();
      square = reduced;
    }
    final png = await square.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return null;
    return criticalPngChunks(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
  } finally {
    square.dispose();
  }
}

/// Rounds each colour channel of premultiplied [rgba] to a multiple of
/// 2^[bits], never above its alpha (which is kept).
void _dropLowBits(Uint8List rgba, int bits) {
  final step = 1 << bits;
  final half = step >> 1;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final alpha = rgba[i + 3];
    for (var c = i; c < i + 3; c++) {
      final rounded = ((rgba[c] + half) ~/ step) * step;
      rgba[c] = rounded > alpha ? alpha : rounded;
    }
  }
}

Future<ui.Image> _fromPixels(Uint8List rgba, int side) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    side,
    side,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

/// [png] with only its critical chunks (IHDR, PLTE, IDAT, IEND) and the
/// transparency chunk: no text, time, colour profile or other metadata.
Uint8List criticalPngChunks(Uint8List png) {
  final out = BytesBuilder(copy: false)..add(png.sublist(0, 8));
  final data = ByteData.sublistView(png);
  var i = 8;
  while (i + 12 <= png.length) {
    final length = data.getUint32(i);
    final end = i + 12 + length;
    if (end > png.length) break;
    final type = String.fromCharCodes(png, i + 4, i + 8);
    final critical = type.codeUnitAt(0) < 0x61; // upper case first letter
    if (critical || type == 'tRNS') out.add(png.sublist(i, end));
    i = end;
    if (type == 'IEND') break;
  }
  return out.takeBytes();
}
