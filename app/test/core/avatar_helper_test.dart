import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/avatar_helper.dart';

/// A PNG of [width] × [height] whose pixel at (x, y) is [color] (RGBA).
Future<Uint8List> _png(
  int width,
  int height,
  List<int> Function(int x, int y) color,
) async {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      pixels.setAll((y * width + x) * 4, color(x, y));
    }
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  final image = await done.future;
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

/// The pixels of the image in [bytes]: its size and RGBA bytes.
Future<(int, int, Uint8List)> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = (image.width, image.height, rgba!.buffer.asUint8List());
  image.dispose();
  codec.dispose();
  return result;
}

int _count(Uint8List haystack, List<int> needle) {
  var count = 0;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var same = true;
    for (var j = 0; j < needle.length && same; j++) {
      same = haystack[i + j] == needle[j];
    }
    if (same) count++;
  }
  return count;
}

/// Checks [uri] is a PNG data URI within the limit whose bytes are a square
/// PNG, and returns the decoded picture.
Future<(int, int, Uint8List)> _checkAvatar(String uri) async {
  expect(uri.length, lessThanOrEqualTo(AvatarData.maxCreatedLength));
  expect(uri, startsWith('data:image/png;base64,'));
  final data = AvatarData.parse(uri, maxLength: AvatarData.maxCreatedLength);
  expect(data, isNotNull);
  expect(data!.type, AvatarType.png);
  expect(data.bytes.sublist(0, 8), [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ]);
  expect(data.width, data.height);
  final decoded = await _decode(data.bytes);
  expect((decoded.$1, decoded.$2), (data.width, data.height));
  return decoded;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a landscape photo becomes its centre square, not squashed', () async {
    // Blue | red | green thirds: only the red middle is left after cropping.
    final photo = await _png(
      300,
      100,
      (x, y) => x < 100
          ? [0, 0, 255, 255]
          : x < 200
          ? [255, 0, 0, 255]
          : [0, 255, 0, 255],
    );
    final uri = await makeAvatarDataUri(photo);
    final (width, height, rgba) = await _checkAvatar(uri);
    expect(width, 64);
    for (final (x, y) in [(0, 0), (width - 1, 0), (0, height - 1)]) {
      final i = (y * width + x) * 4;
      expect(rgba[i], greaterThan(200), reason: 'red at ($x, $y)');
      expect(rgba[i + 1], lessThan(40), reason: 'no green at ($x, $y)');
      expect(rgba[i + 2], lessThan(40), reason: 'no blue at ($x, $y)');
    }
  });

  test(
    'a JPEG with EXIF becomes a small PNG with none of its metadata',
    () async {
      final jpeg = File('test/core/fixtures/landscape_exif.jpg')
          .readAsBytesSync();
      // The fixture carries EXIF (APP1) with a camera name and GPS position.
      expect(_count(jpeg, [0xFF, 0xE1]), greaterThan(0));
      expect(_count(jpeg, 'SecretCam'.codeUnits), greaterThan(0));

      final uri = await makeAvatarDataUri(jpeg);
      final (width, height, _) = await _checkAvatar(uri);
      expect((width, height), (64, 64));
      final png = AvatarData.parse(uri)!.bytes;
      expect(_count(png, 'SecretCam'.codeUnits), 0);
      expect(_count(png, 'Exif'.codeUnits), 0);
      for (final chunk in ['eXIf', 'tEXt', 'iTXt', 'zTXt', 'tIME', 'iCCP']) {
        expect(_count(png, chunk.codeUnits), 0, reason: chunk);
      }
    },
  );

  test('even pure noise, the hardest to compress, fits the limit', () async {
    final random = Random(1);
    final noise = await _png(
      512,
      512,
      (x, y) => [
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        255,
      ],
    );
    final uri = await makeAvatarDataUri(noise);
    await _checkAvatar(uri);
  });

  test('a portrait image is cropped to a square too', () async {
    final uri = await makeAvatarDataUri(
      await _png(40, 200, (x, y) => [x * 6, y, 128, 255]),
    );
    final (width, height, _) = await _checkAvatar(uri);
    expect((width, height), (64, 64));
  });

  test('files that are not images are refused, not passed through', () async {
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList('not an image'.codeUnits),
      Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0, 4, 1, 2]),
    ]) {
      await expectLater(
        makeAvatarDataUri(bytes),
        throwsA(
          isA<AvatarException>().having(
            (e) => e.error,
            'error',
            AvatarError.unreadable,
          ),
        ),
      );
    }
  });

  test('files over 10 MB are refused', () async {
    await expectLater(
      makeAvatarDataUri(Uint8List(maxAvatarInputBytes + 1)),
      throwsA(
        isA<AvatarException>().having(
          (e) => e.error,
          'error',
          AvatarError.inputTooLarge,
        ),
      ),
    );
  });

  test('a picture that cannot be made small enough throws', () async {
    await expectLater(
      makeAvatarDataUri(
        await _png(64, 64, (x, y) => [x * 4, y * 4, 0, 255]),
        maxLength: 100,
      ),
      throwsA(
        isA<AvatarException>().having(
          (e) => e.error,
          'error',
          AvatarError.tooLarge,
        ),
      ),
    );
  });
}
