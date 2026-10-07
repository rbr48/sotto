import 'dart:convert';
import 'dart:typed_data';

/// Unpadded base64url, the text encoding for every key, nonce and ciphertext
/// in the Sotto protocol.
String b64Encode(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Decodes unpadded base64url. Throws [FormatException] for anything that is
/// not the canonical encoding (padding, other alphabets, trailing bits), so a
/// value has exactly one valid text form.
Uint8List b64Decode(String text) {
  if (text.contains('=')) throw const FormatException('padding not allowed');
  final padded = text.padRight((text.length + 3) ~/ 4 * 4, '=');
  final bytes = base64Url.decode(padded);
  if (b64Encode(bytes) != text) {
    throw const FormatException('non-canonical base64url');
  }
  return bytes;
}

/// Concatenates byte lists.
Uint8List concatBytes(List<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.toBytes();
}

/// UTF-8 domain-separation label followed by a zero byte.
Uint8List domainLabel(String label) => concatBytes([
  utf8.encode(label),
  const [0],
]);

/// Byte-wise equality for public values (keys, ids). Not constant time.
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
