import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sodium/sodium.dart';

import '../call/call_controller.dart';
import '../call/devices.dart';
import '../contacts/contact_book.dart';
import '../core/server_address.dart';
import '../core/test_hooks.dart';
import '../crypto/encoding.dart';
import '../crypto/sotto_crypto.dart';
import '../desktop/notices.dart';
import '../guest/guest_link.dart';
import '../history/call_history.dart';
import '../lock/app_lock.dart';
import '../sound/call_sounds.dart';
import '../storage/backup.dart';
import '../storage/vault.dart';
import '../storage/vault_file.dart';

enum AppStage {
  loading,

  /// Startup failed; see [AppController.error].
  failed,

  /// The vault exists but can't be opened; see [AppController.error].
  vaultProblem,

  /// No identity or profile yet: show onboarding.
  onboarding,
  ready,
}

/// The professional's name and practice, shown on guest links and contact
/// links. Stored in the vault.
@immutable
class Profile {
  const Profile({required this.name, this.practice = ''});

  final String name;
  final String practice;

  /// "Name (Practice)".
  String get label => practice.isEmpty ? name : '$name ($practice)';

  String encode() => jsonEncode({'name': name, 'practice': practice});

  static Profile? decode(String? stored) {
    if (stored == null) return null;
    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      return Profile(
        name: json['name'] as String,
        practice: json['practice'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// The professional's app: identity, encrypted storage, profile, app lock,
/// contacts, call history, devices and backups. Creates the
/// [CallController] once the user has an identity and a profile.
///
/// In the browser ([persistent] false) everything lives in memory and is
/// gone when the tab closes.
class AppController extends ChangeNotifier {
  AppController({
    required this.relayUrl,
    required this.linkBase,
    bool? persistent,
    SecretStore? keystore,
    Future<VaultFile> Function()? openVaultFile,
    DeviceLister Function()? deviceLister,
    this.startCalls = true,
  }) : _deviceLister = deviceLister ?? WebRtcDeviceLister.new,
       _persistent = persistent ?? !kIsWeb,
       _keystore =
           keystore ??
           ((persistent ?? !kIsWeb) ? OsSecretStore() : MemorySecretStore()),
       _openVaultFile =
           openVaultFile ??
           ((persistent ?? !kIsWeb)
               ? defaultVaultFile
               : () async => MemoryVaultFile());

  static const String profileKey = 'sotto.profile.v1';

  static const String desktopKey = 'sotto.settings.desktop';

  /// A server chosen by the user instead of the built-in one.
  static const String serverKey = 'sotto.server.v1';
  static const String legacyHostNameKey = 'sotto.settings.host_name';

  /// Settings that earlier versions kept directly in the OS keystore.
  static const List<String> legacyKeys = [
    CallController.hideIpSetting,
    legacyHostNameKey,
    ContactBook.legacyTrustedKey,
    GuestLinkStore.storageKey,
  ];

  final Uri relayUrl;
  final Uri linkBase;

  /// Whether data survives restarts (native apps) or lives only in memory
  /// (browser, or a session without the system keystore).
  bool get persistent => _persistent;
  bool _persistent;

  /// Tests can skip connecting to a relay.
  final bool startCalls;

  SecretStore _keystore;
  Future<VaultFile> Function() _openVaultFile;
  final DeviceLister Function() _deviceLister;

  AppStage _stage = AppStage.loading;
  AppStage get stage => _stage;

  String? error;

  /// Startup failed because the OS keystore can't be used.
  bool keystoreMissing = false;

  Sodium? _sodium;
  Sodium get sodium => _sodium!;
  Vault? _vault;
  VaultFile? _vaultFile;
  Identity? _identity;
  Timer? _purgeTimer;

  Profile? _profile;
  Profile? get profile => _profile;

  /// A name to suggest during onboarding (from an earlier version).
  String suggestedName = '';

  /// Whether an identity already exists (onboarding then only asks for the
  /// name).
  bool get hasIdentity => _identity != null;

  late AppLock lock;
  late ContactBook contacts;
  late CallHistory history;
  late DeviceSettings devices;

  CallController? _calls;
  CallController? get calls => _calls;

  ServerAddress? _customServer;

  DesktopPrefs _desktopPrefs = const DesktopPrefs();

  bool _trayAvailable = false;

  /// Whether a tray icon could be shown (desktop apps).
  bool get trayAvailable => _trayAvailable;
  set trayAvailable(bool value) {
    _trayAvailable = value;
    notifyListeners();
  }

  /// Tray and notification choices (desktop apps).
  DesktopPrefs get desktopPrefs => _desktopPrefs;

  Future<void> setDesktopPrefs(DesktopPrefs prefs) async {
    _desktopPrefs = prefs;
    notifyListeners();
    await _vault?.write(desktopKey, prefs.encode());
  }

  /// The built-in server (from the build configuration).
  ServerAddress get defaultServer =>
      ServerAddress(web: linkBase, relay: relayUrl);

  /// The server in use: the user's choice, or the built-in one.
  ServerAddress get server => _customServer ?? defaultServer;

  /// Whether the user chose another server (not possible in the browser,
  /// which always uses the server it was loaded from).
  bool get usesCustomServer => _customServer != null;
  bool get canChangeServer => persistent;

  /// Backups need Argon2id and a device that keeps the identity.
  bool get backupsAvailable =>
      persistent && SottoCrypto.passwordHashing(sodium) != null;

  Future<void> start() async {
    _setStage(AppStage.loading);
    try {
      _sodium ??= await SottoCrypto.init();
      final file = _vaultFile = await _openVaultFile();
      try {
        await _keystore.read(Vault.keyName);
      } catch (e) {
        error =
            'The system keystore is not available ($e). On Linux, Sotto '
            'needs a Secret Service such as GNOME Keyring or KWallet.';
        keystoreMissing = true;
        _setStage(AppStage.failed);
        return;
      }
      final Vault vault;
      try {
        vault = await Vault.open(sodium: sodium, keys: _keystore, file: file);
      } on VaultException catch (e) {
        error = e.message;
        _setStage(AppStage.vaultProblem);
        return;
      }
      _vault?.dispose();
      _vault = vault;
      await vault.migrateFrom(_keystore, legacyKeys);
      await _loadStores(vault);
      _identity?.dispose();
      _identity = await IdentityStore(sodium, _keystore).load();
      if (_identity == null || _profile == null) {
        suggestedName = await vault.read(legacyHostNameKey) ?? '';
        _setStage(AppStage.onboarding);
        return;
      }
      await _startCalls();
    } catch (e) {
      error = '$e';
      _setStage(AppStage.failed);
    }
  }

  Future<void> _loadStores(Vault vault) async {
    final sumo = SottoCrypto.passwordHashing(sodium);
    lock = AppLock(
      vault,
      persistent && sumo != null
          ? Argon2PinHasher(sumo)
          : SessionPinHasher(sodium),
    );
    contacts = ContactBook(vault);
    history = CallHistory(vault);
    devices = DeviceSettings(vault, _deviceLister());
    await lock.load();
    await contacts.load();
    await history.load();
    _profile = Profile.decode(await vault.read(profileKey));
    _desktopPrefs = DesktopPrefs.decode(await vault.read(desktopKey));
    _customServer = canChangeServer
        ? ServerAddress.decode(await vault.read(serverKey))
        : null;
  }

  /// Onboarding: creates the identity (if there is none yet) and saves the
  /// profile.
  Future<void> completeOnboarding({
    required String name,
    String practice = '',
  }) async {
    _identity ??= await IdentityStore(sodium, _keystore).loadOrCreate();
    await updateProfile(name: name, practice: practice);
    await _vault!.delete(legacyHostNameKey);
    await _startCalls();
  }

  Future<void> updateProfile({
    required String name,
    String practice = '',
  }) async {
    final profile = _profile = Profile(
      name: name.trim(),
      practice: practice.trim(),
    );
    await _vault!.write(profileKey, profile.encode());
    _calls?.publishGuestLinks();
    notifyListeners();
  }

  Future<void> _startCalls() async {
    try {
      await devices.load();
    } catch (_) {
      // No device list (e.g. permissions): defaults are used.
    }
    _purgeTimer?.cancel();
    _purgeTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(history.purge()),
    );
    if (startCalls) {
      final calls = _calls = CallController(
        relayUrl: server.relay,
        linkBase: server.web,
        identity: _identity,
        settings: _vault,
        contacts: contacts,
        history: history,
        devices: devices,
        hostName: () => _profile?.label ?? '',
        sounds: AudioplayersOutput(),
      );
      await calls.start();
    }
    publishForTests('stage', 'ready');
    _setStage(AppStage.ready);
  }

  /// Switches to another server (`null` = the built-in one) and reconnects.
  /// Links shared earlier point to the old server.
  Future<void> setServer(ServerAddress? server) async {
    if (!canChangeServer) return;
    _customServer = server == defaultServer ? null : server;
    if (_customServer case final custom?) {
      await _vault!.write(serverKey, custom.encode());
    } else {
      await _vault!.delete(serverKey);
    }
    if (_stage == AppStage.ready) {
      _purgeTimer?.cancel();
      _calls?.dispose();
      _calls = null;
      await _startCalls();
    }
    notifyListeners();
  }

  /// Creates an encrypted backup of the identity and the vault (without
  /// device-only settings such as the app lock). Throws [BackupException].
  Future<String> exportBackup(
    String passphrase, {
    bool includeHistory = true,
  }) async {
    final sumo = SottoCrypto.passwordHashing(sodium);
    final stored = await _keystore.read(IdentityStore.masterSecretKey);
    if (sumo == null || stored == null) {
      throw StateError('backups are not available here');
    }
    final values = _vault!.snapshot()
      ..removeWhere(
        (key, _) =>
            Backup.deviceOnlyKeys.contains(key) ||
            (!includeHistory && key == CallHistory.storageKey),
      );
    final master = b64Decode(stored);
    try {
      return Backup.create(
        sumo,
        passphrase: passphrase,
        masterSecret: master,
        values: values,
      );
    } finally {
      master.fillRange(0, master.length, 0);
    }
  }

  /// Restores a backup, replacing this device's identity and data (the app
  /// lock and device choices stay). Throws [BackupException].
  Future<void> restoreBackup(String text, String passphrase) async {
    final sumo = SottoCrypto.passwordHashing(sodium);
    if (sumo == null) throw StateError('backups are not available here');
    final contents = Backup.open(sumo, text, passphrase);
    _stopCalls();
    final vault = _vault!;
    final kept = {
      for (final key in Backup.deviceOnlyKeys) key: ?await vault.read(key),
    };
    await _keystore.write(
      IdentityStore.masterSecretKey,
      b64Encode(contents.masterSecret),
    );
    contents.masterSecret.fillRange(0, contents.masterSecret.length, 0);
    await vault.replaceAll({...contents.values, ...kept});
    await start();
  }

  /// Without a keystore: run with a temporary identity and nothing stored,
  /// like the browser.
  Future<void> startTemporarySession() async {
    _persistent = false;
    keystoreMissing = false;
    _keystore = MemorySecretStore();
    _openVaultFile = () async => MemoryVaultFile();
    await start();
  }

  /// Deletes the identity and all data from this device.
  Future<void> eraseEverything() async {
    _stopCalls();
    await IdentityStore(sodium, _keystore).delete();
    await Vault.erase(keys: _keystore, file: _vaultFile!);
    _vault?.dispose();
    _vault = null;
    _profile = null;
    await start();
  }

  /// When the vault can't be opened: start with empty storage (the identity
  /// in the keystore is kept).
  Future<void> resetStorage() async {
    await Vault.erase(keys: _keystore, file: _vaultFile!);
    await start();
  }

  void _stopCalls() {
    _purgeTimer?.cancel();
    _calls?.dispose();
    _calls = null;
    devices.dispose();
  }

  void _setStage(AppStage stage) {
    _stage = stage;
    notifyListeners();
  }

  @override
  void dispose() {
    _purgeTimer?.cancel();
    _calls?.dispose();
    _identity?.dispose();
    _vault?.dispose();
    super.dispose();
  }
}
