import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Triggers a direct browser file download for the given bytes.
void downloadWebFile(Uint8List bytes, String fileName, [String? mime]) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mime ?? 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  anchor.download = fileName;
  anchor.click();
  Timer(const Duration(seconds: 15), () {
    web.URL.revokeObjectURL(url);
  });
}

/// Opens the file for preview in a new tab if supported by the browser,
/// or triggers a download otherwise.
void openWebFile(Uint8List bytes, String fileName, [String? mime]) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mime ?? 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  if (_canBrowserPreview(mime, fileName)) {
    anchor.target = '_blank';
  } else {
    anchor.download = fileName;
  }
  anchor.click();
  Timer(const Duration(seconds: 15), () {
    web.URL.revokeObjectURL(url);
  });
}

bool _canBrowserPreview(String? mime, String fileName) {
  if (mime != null) {
    final lower = mime.toLowerCase();
    if (lower == 'application/pdf' ||
        lower.startsWith('image/') ||
        lower.startsWith('video/') ||
        lower.startsWith('audio/') ||
        lower.startsWith('text/')) {
      return true;
    }
  }
  final lowerName = fileName.toLowerCase();
  return lowerName.endsWith('.pdf') ||
      lowerName.endsWith('.png') ||
      lowerName.endsWith('.jpg') ||
      lowerName.endsWith('.jpeg') ||
      lowerName.endsWith('.webp') ||
      lowerName.endsWith('.gif') ||
      lowerName.endsWith('.svg') ||
      lowerName.endsWith('.txt');
}
