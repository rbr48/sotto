import 'dart:typed_data';

/// The bytes and the MIME type (codec parameters included) of a blob URL.
typedef VoiceBlob = ({Uint8List bytes, String type});

/// Blob URLs exist only in the browser. The native apps record to files.
Future<VoiceBlob> readVoiceBlob(String url) =>
    throw UnsupportedError('blob URLs exist only in the browser');

void revokeVoiceBlob(String url) {}
