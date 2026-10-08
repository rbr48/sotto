import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sodium/sodium.dart';

import '../call/call_code.dart';
import '../crypto/encoding.dart';
import '../crypto/identity.dart';

/// Someone's contact details from a contact link, QR code or call link.
@immutable
class ContactInvite {
  const ContactInvite({required this.identity, this.name, this.organisation});

  final PublicIdentity identity;

  /// Name and organisation as the person describes themselves (signed by
  /// their key, but self-asserted). `null` for plain call links.
  final String? name;
  final String? organisation;
}

/// Contact links let colleagues add each other: `https://<host>/#c=<payload>`
/// (after `#`, so the details never reach a web server).
///
/// `payload = base64url(JSON {v:1, card, n, o?, sig})`, where
/// `sig = Ed25519("sotto-contact-v1\0" || JSON[sign, box, n, o])`.
abstract final class ContactLink {
  static const int version = 1;
  static const String fragmentKey = 'c';
  static const int maxNameLength = 80;

  static List<int> _signedBytes(
    PublicIdentity identity,
    String name,
    String? organisation,
  ) => concatBytes([
    domainLabel('sotto-contact-v1'),
    utf8.encode(
      jsonEncode([
        b64Encode(identity.signKey),
        b64Encode(identity.boxKey),
        name,
        organisation,
      ]),
    ),
  ]);

  static String create(
    Sodium sodium,
    Identity identity, {
    required Uri base,
    required String name,
    String? organisation,
  }) {
    final org = (organisation?.trim().isEmpty ?? true)
        ? null
        : organisation!.trim();
    final signature = sodium.crypto.sign.detached(
      message: Uint8List.fromList(
        _signedBytes(identity.publicIdentity, name.trim(), org),
      ),
      secretKey: identity.signSecretKey,
    );
    final payload = b64Encode(
      utf8.encode(
        jsonEncode({
          'v': version,
          'card': identity.card(sodium).toJson(),
          'n': name.trim(),
          'o': ?org,
          'sig': b64Encode(signature),
        }),
      ),
    );
    final page = Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: base.path.isEmpty ? '/' : base.path,
    );
    return '$page#$fragmentKey=$payload';
  }

  /// A short contact link, `https://<host>/#c=<signing key>`: the details
  /// are looked up from the person's app (see ProfileExchange).
  static String createShort(Uri base, PublicIdentity identity) =>
      '${_page(base)}#$fragmentKey=${identity.id}';

  /// A short call link, `https://<host>/?call=<signing key>`: opening it
  /// calls the person right away.
  static String createShortCall(Uri base, PublicIdentity identity) =>
      '${_page(base)}?call=${identity.id}';

  static Uri _page(Uri base) => Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: base.path.isEmpty ? '/' : base.path,
  );

  /// The signing key in a short link (or a bare key), or null when [input]
  /// is a full link or not a link at all.
  static Uint8List? shortKeyOf(String input) {
    final text = input.trim();
    String? value;
    final hash = text.indexOf('#');
    if (hash >= 0) {
      for (final part in text.substring(hash + 1).split('&')) {
        if (part.startsWith('$fragmentKey=')) value = part.substring(2);
      }
    }
    value ??= Uri.tryParse(text)?.queryParameters['call'];
    value ??= text;
    if (value.length != 43) return null;
    try {
      final key = b64Decode(value);
      return key.length == 32 ? key : null;
    } on FormatException {
      return null;
    }
  }

  /// Whether [input] looks like a contact link (`#c=`).
  static bool isContactLink(String input) =>
      input.contains('#$fragmentKey=') || input.contains('&$fragmentKey=');

  /// Accepts a contact link, a call link (`?call=`) or a bare call code.
  /// Throws [InvalidIdentityException] if it is none of these or was altered.
  static ContactInvite parse(Sodium sodium, String input) {
    final text = input.trim();
    final hash = text.indexOf('#');
    if (hash >= 0) {
      for (final part in text.substring(hash + 1).split('&')) {
        if (part.startsWith('$fragmentKey=')) {
          return _parsePayload(sodium, part.substring(2));
        }
      }
    }
    return ContactInvite(identity: CallCode.parse(sodium, text));
  }

  static ContactInvite _parsePayload(Sodium sodium, String payload) {
    final PublicIdentity identity;
    final String name;
    final String? organisation;
    final Uint8List signature;
    try {
      final json =
          jsonDecode(utf8.decode(b64Decode(payload))) as Map<String, dynamic>;
      if (json['v'] != version) throw const FormatException();
      identity = IdentityCard.verify(sodium, json['card']);
      name = json['n'] as String;
      organisation = json['o'] as String?;
      signature = b64Decode(json['sig'] as String);
      if (name.isEmpty ||
          name.length > maxNameLength ||
          (organisation?.length ?? 0) > maxNameLength ||
          signature.length != 64) {
        throw const FormatException();
      }
    } on InvalidIdentityException {
      rethrow;
    } catch (_) {
      throw const InvalidIdentityException('not a valid contact link');
    }
    final valid = sodium.crypto.sign.verifyDetached(
      message: Uint8List.fromList(_signedBytes(identity, name, organisation)),
      signature: signature,
      publicKey: identity.signKey,
    );
    if (!valid) {
      throw const InvalidIdentityException('contact link was altered');
    }
    return ContactInvite(
      identity: identity,
      name: name,
      organisation: organisation,
    );
  }
}
