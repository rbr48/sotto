import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/avatar_data.dart';

/// The start of a PNG: its signature and an IHDR chunk (CRC not checked).
Uint8List _png(int width, int height, {String firstChunk = 'IHDR'}) {
  final bytes = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add([0, 0, 0, 13])
    ..add(firstChunk.codeUnits);
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  bytes
    ..add(header.buffer.asUint8List())
    ..add([0, 0, 0, 0])
    ..add([0, 0, 0, 0, ...'IEND'.codeUnits, 0xAE, 0x42, 0x60, 0x82]);
  return bytes.takeBytes();
}

List<int> _segment(int marker, List<int> payload) => [
  0xFF,
  marker,
  (payload.length + 2) >> 8,
  (payload.length + 2) & 0xFF,
  ...payload,
];

/// The start of a JPEG: an APP0 and an EXIF APP1, a frame header, a scan.
Uint8List _jpeg(int width, int height, {int frameMarker = 0xC0}) =>
    Uint8List.fromList([
      0xFF, 0xD8, //
      ..._segment(0xE0, 'JFIF\x00'.codeUnits),
      ..._segment(0xE1, 'Exif\x00\x00 something'.codeUnits),
      ..._segment(0xDB, List.filled(65, 1)),
      if (frameMarker != 0)
        ..._segment(frameMarker, [
          8,
          height >> 8,
          height & 0xFF,
          width >> 8,
          width & 0xFF,
          1,
          1,
          0x11,
          0,
        ]),
      ..._segment(0xDA, [1, 1, 0, 0, 0x3F, 0]),
      0x12, 0x34, 0xFF, 0xD9, //
    ]);

String _uri(String mime, List<int> bytes) =>
    'data:$mime;base64,${base64Encode(bytes)}';

void main() {
  test('reads the size from PNG and JPEG headers', () {
    expect(AvatarData.pngSize(_png(64, 48)), (64, 48));
    expect(AvatarData.jpegSize(_jpeg(96, 80)), (96, 80));
    expect(AvatarData.jpegSize(_jpeg(30, 20, frameMarker: 0xC2)), (30, 20));
  });

  test('accepts small JPEG and PNG data URIs of the type they claim', () {
    final png = AvatarData.parse(_uri('image/png', _png(64, 64)))!;
    expect((png.type, png.width, png.height), (AvatarType.png, 64, 64));
    final jpeg = AvatarData.parse(_uri('image/jpeg', _jpeg(512, 300)))!;
    expect((jpeg.type, jpeg.width, jpeg.height), (AvatarType.jpeg, 512, 300));
  });

  test('drops anything else', () {
    final bad = <String, String?>{
      'missing': null,
      'empty': '',
      'not a data URI': base64Encode(_png(8, 8)),
      'another type': _uri('image/gif', _png(8, 8)),
      'svg': _uri('image/svg+xml', '<svg/>'.codeUnits),
      'not base64': 'data:image/png;base64,***',
      'PNG bytes called JPEG': _uri('image/jpeg', _png(8, 8)),
      'JPEG bytes called PNG': _uri('image/png', _jpeg(8, 8)),
      'too wide': _uri('image/png', _png(513, 10)),
      'too tall': _uri('image/jpeg', _jpeg(10, 4000)),
      'no pixels': _uri('image/png', _png(0, 10)),
      'PNG without IHDR first': _uri(
        'image/png',
        _png(8, 8, firstChunk: 'tEXt'),
      ),
      'JPEG without a frame header': _uri(
        'image/jpeg',
        _jpeg(8, 8, frameMarker: 0),
      ),
      'truncated JPEG': _uri('image/jpeg', _jpeg(8, 8).sublist(0, 30)),
      'too long': _uri('image/png', [..._png(8, 8), ...Uint8List(20000)]),
    };
    for (final entry in bad.entries) {
      expect(AvatarData.parse(entry.value), isNull, reason: entry.key);
    }
  });

  test('the length limit is a parameter', () {
    final uri = _uri('image/png', [..._png(8, 8), ...Uint8List(13000)]);
    expect(uri.length, greaterThan(AvatarData.maxCreatedLength));
    expect(uri.length, lessThan(AvatarData.maxSharedLength));
    expect(AvatarData.isValid(uri), isTrue);
    expect(
      AvatarData.isValid(uri, maxLength: AvatarData.maxCreatedLength),
      isFalse,
    );
    expect(AvatarData.sanitize(uri), uri);
    expect(AvatarData.sanitize('data:image/png;base64,AAAA'), isNull);
  });
}
