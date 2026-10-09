import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// The bytes and the MIME type (codec parameters included) of a blob URL.
typedef VoiceBlob = ({Uint8List bytes, String type});

/// Reads the blob behind [url], which the recorder returned from stop.
Future<VoiceBlob> readVoiceBlob(String url) async {
  final response = await web.window.fetch(url.toJS).toDart;
  final blob = await response.blob().toDart;
  final buffer = await blob.arrayBuffer().toDart;
  return (bytes: buffer.toDart.asUint8List(), type: blob.type);
}

/// Releases the blob behind [url]. Read the bytes first.
void revokeVoiceBlob(String url) => web.URL.revokeObjectURL(url);
