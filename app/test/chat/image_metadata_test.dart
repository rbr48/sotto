import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/chat/image_metadata.dart';

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// The scan data of the test JPEGs: a stuffed zero byte and a restart marker.
const _scan = [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56];

/// A JPEG segment: its marker, its length, then its payload.
Uint8List _segment(int marker, List<int> payload) {
  final length = payload.length + 2;
  return Uint8List.fromList([
    0xFF,
    marker,
    length >> 8,
    length & 0xFF,
    ...payload,
  ]);
}

/// A PNG chunk: its length, its type, its data, and a CRC. The cleaning does
/// not check CRCs, so the CRC here is zeros.
Uint8List _chunk(String type, List<int> data) => _join([
  [
    (data.length >> 24) & 0xFF,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
  ],
  type.codeUnits,
  data,
  const [0, 0, 0, 0],
]);

/// The bytes of [parts], one after another.
Uint8List _join(List<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

Uint8List _ascii(String text) => Uint8List.fromList(text.codeUnits);

/// How many times [needle] appears in [haystack].
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

bool _contains(Uint8List haystack, List<int> needle) =>
    _count(haystack, needle) > 0;

/// A JFIF header, as cameras and editors write it.
final _jfif = [
  ..._segment(0xE0, [
    ...'JFIF'.codeUnits,
    0x00,
    0x01,
    0x01,
    0,
    0,
    1,
    0,
    1,
    0,
    0,
  ]),
];

/// A baseline JPEG with location and camera details in APP1, a comment, one
/// scan, the end marker, and bytes after the end marker.
Uint8List _jpeg() => _join([
  [0xFF, 0xD8],
  _jfif,
  _segment(0xE1, 'Exif GPSLatitude=51.5074'.codeUnits),
  _segment(0xFE, 'secret comment'.codeUnits),
  _segment(0xDB, List<int>.filled(65, 1)),
  _segment(0xDA, [1, 1, 0, 0, 63, 0]),
  _scan,
  [0xFF, 0xD9],
  'trailing-secret'.codeUnits,
]);

/// A PNG with a 1x1 image: IHDR, IDAT and IEND, with the given extra chunks
/// before IEND and bytes after it.
Uint8List _png({
  List<Uint8List> extra = const [],
  List<int> trailing = const [],
}) => _join([
  _pngSignature,
  _chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0]),
  ...extra,
  _chunk('IDAT', [0x78, 0x9C, 0x63, 0x00, 0x00]),
  _chunk('IEND', const []),
  trailing,
]);

/// The width and height of the image that [bytes] decodes to.
Future<(int, int)> _size(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    final size = (frame.image.width, frame.image.height);
    frame.image.dispose();
    return size;
  } finally {
    codec.dispose();
  }
}

void main() {
  test('the type is read from the first bytes, not from anything else', () {
    expect(ImageMetadata.kindOf(_jpeg()), ImageKind.jpeg);
    expect(ImageMetadata.kindOf(_png()), ImageKind.png);
    expect(ImageMetadata.kindOf(_ascii('GIF89a')), isNull);
    expect(ImageMetadata.kindOf(Uint8List(0)), isNull);
  });

  group('JPEG', () {
    test(
      'removes location, comments and trailing bytes, keeps the picture',
      () {
        final out = ImageMetadata.clean(_jpeg(), 'image/jpeg');

        expect(out.sublist(0, 2), [0xFF, 0xD8]);
        expect(out.sublist(out.length - 2), [0xFF, 0xD9]);
        expect(_contains(out, _ascii('GPSLatitude')), isFalse);
        expect(_contains(out, _ascii('secret')), isFalse);
        expect(_contains(out, _ascii('trailing-secret')), isFalse);
        expect(_contains(out, _ascii('JFIF')), isTrue);
        expect(_contains(out, [0xFF, 0xDB]), isTrue);
        expect(_contains(out, _scan), isTrue);
      },
    );

    test('keeps the ICC profile and Adobe segments, drops other APPn', () {
      final jpeg = _join([
        [0xFF, 0xD8],
        _segment(0xE2, [...'ICC_PROFILE'.codeUnits, 0x00, 0x01, 0x01, 0x42]),
        _segment(0xE2, 'FPXR other'.codeUnits),
        _segment(0xEC, 'Ducky secret'.codeUnits),
        _segment(0xED, 'IPTC secret'.codeUnits),
        _segment(0xEE, [...'Adobe'.codeUnits, 0, 100]),
        _segment(0xDB, List<int>.filled(65, 1)),
        _segment(0xDA, [1, 1, 0, 0, 63, 0]),
        _scan,
        [0xFF, 0xD9],
      ]);

      final out = ImageMetadata.clean(jpeg, 'image/jpeg');

      expect(_contains(out, _ascii('ICC_PROFILE')), isTrue);
      expect(_contains(out, _ascii('Adobe')), isTrue);
      expect(_contains(out, _ascii('FPXR')), isFalse);
      expect(_contains(out, _ascii('Ducky')), isFalse);
      expect(_contains(out, _ascii('IPTC')), isFalse);
    });

    test('a progressive JPEG keeps every scan and the tables between them', () {
      const scan1 = [0x11, 0x22, 0xFF, 0x00, 0x33];
      const scan2 = [0x44, 0xFF, 0x00, 0x55];
      final jpeg = _join([
        [0xFF, 0xD8],
        _jfif,
        _segment(0xFE, 'comment'.codeUnits),
        _segment(0xDB, List<int>.filled(65, 1)),
        _segment(0xC2, [
          8,
          0,
          16,
          0,
          16,
          3,
          1,
          0x11,
          0,
          2,
          0x11,
          0,
          3,
          0x11,
          0,
        ]),
        _segment(0xC4, [0x00, ...List<int>.filled(16, 0), 0x00]),
        _segment(0xDA, [1, 1, 0, 0, 63, 0]),
        scan1,
        _segment(0xC4, [0x10, ...List<int>.filled(16, 0), 0x01]),
        _segment(0xDA, [1, 2, 0, 0, 63, 0]),
        scan2,
        [0xFF, 0xD9],
      ]);

      final out = ImageMetadata.clean(jpeg, 'image/jpeg');

      expect(_count(out, [0xFF, 0xDA]), 2);
      expect(_count(out, [0xFF, 0xC4]), 2);
      expect(_contains(out, [0xFF, 0xC2]), isTrue);
      expect(_contains(out, scan1), isTrue);
      expect(_contains(out, scan2), isTrue);
      expect(_contains(out, _ascii('comment')), isFalse);
      expect(out.sublist(out.length - 2), [0xFF, 0xD9]);
    });

    test('a JPEG with nothing to remove comes out byte for byte the same', () {
      final jpeg = _join([
        [0xFF, 0xD8],
        _segment(0xDB, List<int>.filled(65, 1)),
        _segment(0xDA, [1, 1, 0, 0, 63, 0]),
        _scan,
        [0xFF, 0xD9],
      ]);
      expect(ImageMetadata.clean(jpeg, 'image/jpeg'), jpeg);
    });

    test('a truncated JPEG is refused', () {
      final jpeg = _jpeg();
      // Cut inside the APP1 segment.
      expect(
        () => ImageMetadata.clean(jpeg.sublist(0, 30), 'image/jpeg'),
        throwsFormatException,
      );
      // Cut inside the scan, before the end marker.
      expect(
        () => ImageMetadata.clean(
          jpeg.sublist(0, jpeg.length - 20),
          'image/jpeg',
        ),
        throwsFormatException,
      );
    });

    test('a JPEG with no end-of-image marker is refused', () {
      final jpeg = _join([
        [0xFF, 0xD8],
        _segment(0xDB, List<int>.filled(65, 1)),
        _segment(0xDA, [1, 1, 0, 0, 63, 0]),
        _scan,
      ]);
      expect(() => ImageMetadata.stripJpeg(jpeg), throwsFormatException);
    });
  });

  group('PNG', () {
    test(
      'removes text and EXIF chunks and trailing bytes, keeps the image',
      () {
        final ihdr = _chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0]);
        final idat = _chunk('IDAT', [0x78, 0x9C, 0x63, 0x00, 0x00]);
        final iend = _chunk('IEND', const []);
        final gama = _chunk('gAMA', [0, 0, 0xB1, 0x8F]);
        final png = _join([
          _pngSignature,
          ihdr,
          _chunk('tEXt', 'Comment\x00GPSLatitude=51.5074'.codeUnits),
          _chunk('zTXt', 'Comment\x00\x00secret'.codeUnits),
          _chunk('iTXt', 'Comment\x00\x00\x00\x00\x00secret'.codeUnits),
          _chunk('tIME', [7, 230, 10, 9, 12, 0, 0]),
          _chunk('eXIf', 'GPSLatitude'.codeUnits),
          gama,
          idat,
          iend,
          'trailing-secret'.codeUnits,
        ]);

        final out = ImageMetadata.clean(png, 'image/png');

        expect(out.sublist(0, 8), _pngSignature);
        expect(_contains(out, _ascii('tEXt')), isFalse);
        expect(_contains(out, _ascii('zTXt')), isFalse);
        expect(_contains(out, _ascii('iTXt')), isFalse);
        expect(_contains(out, _ascii('tIME')), isFalse);
        expect(_contains(out, _ascii('eXIf')), isFalse);
        expect(_contains(out, _ascii('secret')), isFalse);
        expect(_contains(out, _ascii('GPS')), isFalse);
        expect(_contains(out, ihdr), isTrue);
        expect(_contains(out, gama), isTrue);
        expect(_contains(out, idat), isTrue);
        expect(out.sublist(out.length - iend.length), iend);
      },
    );

    test('a PNG with nothing to remove comes out byte for byte the same', () {
      final png = _png();
      expect(ImageMetadata.clean(png, 'image/png'), png);
    });

    test('a PNG with no IEND chunk is refused', () {
      final png = _join([
        _pngSignature,
        _chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0]),
      ]);
      expect(() => ImageMetadata.stripPng(png), throwsFormatException);
    });

    test('a chunk that runs past the end is refused', () {
      final png = _join([
        _pngSignature,
        [0, 0, 0, 100],
        _ascii('IDAT'),
        [1, 2, 3],
      ]);
      expect(() => ImageMetadata.stripPng(png), throwsFormatException);
    });

    test(
      'a real PNG decodes to the same size before and after cleaning',
      () async {
        final png = Uint8List.fromList(
          File('assets/brand/logo.png').readAsBytesSync(),
        );
        final cleaned = ImageMetadata.clean(png, 'image/png');

        expect(await _size(cleaned), await _size(png));
      },
    );
  });

  group('other input', () {
    test(
      'an image MIME type with bytes that are not a JPEG or PNG is refused',
      () {
        expect(
          () => ImageMetadata.clean(_ascii('GIF89a'), 'image/gif'),
          throwsArgumentError,
        );
      },
    );

    test('a file that is not an image passes through unchanged', () {
      final text = _ascii('Plain text, with no metadata.');
      expect(ImageMetadata.clean(text, 'text/plain'), text);
    });

    test('an image is cleaned whatever its MIME type says', () {
      final out = ImageMetadata.clean(_jpeg(), 'application/octet-stream');
      expect(_contains(out, _ascii('GPSLatitude')), isFalse);
    });
  });
}
