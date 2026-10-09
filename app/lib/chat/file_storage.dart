import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sodium/sodium.dart';

import '../crypto/encoding.dart';

/// A received file that cannot be opened: [reason] is 'missing' (it is no
/// longer on this device, for example after a restore) or 'damaged'.
class ReceivedFileException implements Exception {
  const ReceivedFileException(this.reason);

  final String reason;

  @override
  String toString() => 'ReceivedFileException: $reason';
}

/// Files received from contacts, kept encrypted in the app's private support
/// directory (`docs/FILE_SHARING_PLAN.md`).
///
/// Each file is sealed with its own random key (XChaCha20-Poly1305). [save]
/// returns that key for the caller to keep in the chat record, which lives in
/// the encrypted vault. So deleting the message also makes the file unreadable,
/// even if the file itself could not be deleted.
///
/// Files get random names, not the sender's file id or name. The disk shows
/// nothing about what was sent, and a sender cannot choose a path.
class ReceivedFileStore {
  ReceivedFileStore({
    required this.sodium,
    Future<Directory> Function()? directory,
  }) : _directory = directory ?? _defaultDirectory;

  final Sodium sodium;
  final Future<Directory> Function() _directory;

  /// Names this store gives files: 16 random bytes in hex. Any other stored
  /// path is a plaintext file kept by an earlier version.
  static final _storedName = RegExp(r'^[0-9a-f]{32}$');

  static const _openFolder = 'received_open';

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/received_files');
  }

  /// Encrypts [bytes] into a new file. Returns the name it is stored under
  /// and the base64 key that opens it.
  Future<({String name, String key})> save(Uint8List bytes) async {
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    final name = _hex(sodium.randombytes.buf(16));
    final secret = aead.keygen();
    final rawKey = secret.extractBytes();
    try {
      final nonce = sodium.randombytes.buf(aead.nonceBytes);
      final cipher = aead.encrypt(
        message: bytes,
        nonce: nonce,
        key: secret,
        additionalData: _aad(name),
      );
      final dir = await _directory();
      await dir.create(recursive: true);
      final sink = File('${dir.path}/$name').openWrite();
      sink
        ..add(nonce)
        ..add(cipher);
      await sink.close();
      return (name: name, key: b64Encode(rawKey));
    } finally {
      secret.dispose();
      rawKey.fillRange(0, rawKey.length, 0);
    }
  }

  /// The decrypted bytes of the file stored as [name] under [key].
  Future<Uint8List> read({required String name, required String key}) async {
    if (!_storedName.hasMatch(name)) {
      throw const ReceivedFileException('missing');
    }
    final file = File('${(await _directory()).path}/$name');
    if (!await file.exists()) throw const ReceivedFileException('missing');
    final sealed = await file.readAsBytes();
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonceLength = aead.nonceBytes;
    if (sealed.length < nonceLength + aead.aBytes) {
      throw const ReceivedFileException('damaged');
    }
    final rawKey = b64Decode(key);
    if (rawKey.length != aead.keyBytes) {
      throw const ReceivedFileException('damaged');
    }
    final secret = SecureKey.fromList(sodium, rawKey);
    rawKey.fillRange(0, rawKey.length, 0);
    try {
      return aead.decrypt(
        cipherText: sealed.sublist(nonceLength),
        nonce: sealed.sublist(0, nonceLength),
        key: secret,
        additionalData: _aad(name),
      );
    } catch (_) {
      throw const ReceivedFileException('damaged');
    } finally {
      secret.dispose();
    }
  }

  /// Deletes the file kept at [stored] (a name from [save], or a plaintext
  /// path from an earlier version). A file that is already gone is fine.
  Future<void> remove(String? stored) async {
    if (stored == null || stored.startsWith('web:')) return;
    try {
      if (_storedName.hasMatch(stored)) {
        final file = File('${(await _directory()).path}/$stored');
        if (await file.exists()) {
          await file.delete();
        }
      } else {
        final file = File(stored);
        if (await file.exists()) {
          await file.delete();
          // Earlier versions kept each file in its own folder, which is
          // removed only if nothing else is in it.
          try {
            await file.parent.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Writes a decrypted copy of [bytes] for another app to open. These copies
  /// are plaintext in the temporary folder, so they are removed by
  /// [clearOpenCopies] and [eraseAll].
  Future<File> writeOpenCopy(String fileName, Uint8List bytes) async {
    final root = await getTemporaryDirectory();
    final folder = Directory(
      '${root.path}/$_openFolder/${_hex(sodium.randombytes.buf(8))}',
    );
    await folder.create(recursive: true);
    final file = File('${folder.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Removes decrypted copies left by [writeOpenCopy].
  Future<void> clearOpenCopies() async {
    if (kIsWeb) return;
    try {
      final root = await getTemporaryDirectory();
      final folder = Directory('${root.path}/$_openFolder');
      if (await folder.exists()) await folder.delete(recursive: true);
    } catch (_) {}
  }

  /// Deletes every received file on this device (for "erase everything" and
  /// for a reset after the vault could not be opened).
  Future<void> eraseAll() async {
    if (kIsWeb) return;
    await clearOpenCopies();
    try {
      final dir = await _directory();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static Uint8List _aad(String name) =>
      Uint8List.fromList(utf8.encode('sotto.file.v1:$name'));

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
