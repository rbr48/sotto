import 'dart:convert';

import 'package:sodium/sodium.dart';

import '../crypto/encoding.dart';
import '../crypto/identity.dart';

/// A "call code" is a person's signed identity card, encoded as unpadded
/// base64url so it fits in a link: `https://<host>/?call=<code>`.
///
/// Anyone with the code can call that person. It contains only public keys.
/// (Phase 5 replaces this with signed guest links that can expire and be
/// revoked.)
abstract final class CallCode {
  static String encode(IdentityCard card) =>
      b64Encode(utf8.encode(card.encode()));

  static String link(Uri base, IdentityCard card) => Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: base.path.isEmpty ? '/' : base.path,
    queryParameters: {'call': encode(card)},
  ).toString();

  /// Accepts a bare code or any link containing `call=<code>`.
  /// Throws [InvalidIdentityException] if it is not a valid, signed card.
  static PublicIdentity parse(Sodium sodium, String input) {
    var code = input.trim();
    final fromLink = Uri.tryParse(code)?.queryParameters['call'];
    if (fromLink != null) code = fromLink;
    final String json;
    try {
      json = utf8.decode(b64Decode(code));
    } on FormatException {
      throw const InvalidIdentityException('not a Sotto call link or code');
    }
    return IdentityCard.verify(sodium, json);
  }
}
