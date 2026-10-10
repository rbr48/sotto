import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sodium/sodium.dart';

import '../desktop/desktop_updater.dart';

import '../android/android_integration.dart';
import '../call/call_controller.dart';
import '../core/update_check.dart';
import '../call/devices.dart';
import '../chat/file_storage.dart';
import '../contacts/contact_book.dart';
import '../core/config.dart';
import '../core/leave_warning.dart';
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
import '../storage/browser_storage.dart';
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
  const Profile({required this.name, this.practice = '', this.avatar});

  final String name;
  final String practice;

  /// Optional base64 profile picture string.
  final String? avatar;

  /// "Name (Practice)".
  String get label => practice.isEmpty ? name : '$name ($practice)';

  String encode() => jsonEncode({
    'name': name,
    'practice': practice,
    if (avatar != null && avatar!.isNotEmpty) 'avatar': avatar!,
  });

  static Profile? decode(String? stored) {
    if (stored == null) return null;
    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      return Profile(
        name: json['name'] as String,
        practice: json['practice'] as String? ?? '',
        avatar: json['avatar'] as String?,
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
/// gone when the tab closes, unless the user chose "Remember me on this
/// browser" ([rememberedInBrowser]).
class AppController extends ChangeNotifier {
  AppController({
    required this.relayUrl,
    required this.linkBase,
    bool? persistent,
    SecretStore? keystore,
    Future<VaultFile> Function()? openVaultFile,
    DeviceLister Function()? deviceLister,
    BrowserStorageBackend? browserStorage,
    this.startCalls = true,
    UpdateChecker? updateChecker,
    this.formerDefaultHosts = SottoConfig.formerDefaultHosts,
  }) : _updates =
           updateChecker ?? (kIsWeb || !startCalls ? null : UpdateChecker()),
       _deviceLister = deviceLister ?? WebRtcDeviceLister.new,
       _browser = browserStorage ?? defaultBrowserStorage(),
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

  /// The key of the browser's PIN hash (see [SessionPinHasher]); kept with
  /// the identity's secrets.
  static const String pinKeyName = 'sotto.lock.key.v1';

  static const String desktopKey = 'sotto.settings.desktop';

  /// The release the user chose not to be reminded of.
  static const String updateDismissedKey = 'sotto.update.dismissed';

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

  /// Hosts of earlier built-in servers: a choice of one of these is
  /// replaced by the built-in server.
  final Set<String> formerDefaultHosts;

  /// Whether data survives restarts (native apps) or lives only in memory
  /// (browser, or a session without the system keystore).
  bool get persistent => _persistent;
  bool _persistent;

  /// Tests can skip connecting to a relay (and checking for updates).
  final bool startCalls;

  SecretStore _keystore;
  Future<VaultFile> Function() _openVaultFile;
  final DeviceLister Function() _deviceLister;
  final BrowserStorageBackend _browser;
  bool _lookedInBrowser = false;

  /// Whether this browser remembers the identity across reloads.
  bool get rememberedInBrowser => _rememberedInBrowser;
  bool _rememberedInBrowser = false;

  /// Whether "Remember me on this browser" can be offered: in the browser,
  /// not in the native apps (which always keep the identity).
  bool get canRememberInBrowser =>
      _browser.supported && (!_persistent || _rememberedInBrowser);

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

  /// Android's background ringing and its permissions (Android app only).
  AndroidIntegration? android;

  /// Whether a tray icon could be shown (desktop apps).
  bool get trayAvailable => _trayAvailable;
  set trayAvailable(bool value) {
    _trayAvailable = value;
    notifyListeners();
  }

  /// Tray and notification choices (desktop apps).
  DesktopPrefs get desktopPrefs => _desktopPrefs;

  Future<void> setDesktopPrefs(DesktopPrefs prefs) async {
    final updatesChanged = prefs.checkUpdates != _desktopPrefs.checkUpdates;
    _desktopPrefs = prefs;
    if (updatesChanged) _scheduleUpdateChecks();
    notifyListeners();
    await _vault?.write(desktopKey, prefs.encode());
  }

  /// `null` in the browser (its server always serves the current version).
  final UpdateChecker? _updates;
  final DesktopUpdater _updater = DesktopUpdater();
  Timer? _updateTimer;
  UpdateInfo? _update;
  String? _dismissedUpdate;
  double? _updateProgress;
  File? _downloadedUpdateFile;
  bool _isDownloadingUpdate = false;
  String? _updateError;

  /// A newer release, unless the user dismissed it.
  UpdateInfo? get availableUpdate =>
      _update?.version == _dismissedUpdate ? null : _update;

  /// Whether this app can check for updates (native apps).
  bool get canCheckUpdates => _updates?.endpoint != null;

  /// Progress of the update download (`0.0` to `1.0`), or `null` if not downloading.
  double? get updateProgress => _updateProgress;

  /// Whether an update download is currently active.
  bool get isDownloadingUpdate => _isDownloadingUpdate;

  /// Downloaded installer package ready to be applied.
  File? get downloadedUpdateFile => _downloadedUpdateFile;

  /// Error message if the update download failed.
  String? get updateError => _updateError;

  /// Starts downloading the update package in the background.
  Future<void> startUpdateDownload() async {
    final update = availableUpdate;
    if (update == null || update.assetUrl == null) return;
    _isDownloadingUpdate = true;
    _updateProgress = 0.0;
    _updateError = null;
    notifyListeners();

    try {
      final file = await _updater.download(
        update,
        onProgress: (p) {
          _updateProgress = p;
          notifyListeners();
        },
      );
      _downloadedUpdateFile = file;
      _isDownloadingUpdate = false;
      _updateProgress = 1.0;
      notifyListeners();
    } catch (e) {
      _isDownloadingUpdate = false;
      _updateProgress = null;
      _updateError = e.toString();
      notifyListeners();
    }
  }

  /// Cancels an in-progress update download.
  void cancelUpdateDownload() {
    _updater.cancel();
    _isDownloadingUpdate = false;
    _updateProgress = null;
    notifyListeners();
  }

  /// Silently installs the downloaded update and relaunches the app.
  Future<void> applyUpdate() async {
    final file = _downloadedUpdateFile;
    if (file == null) return;
    await DesktopUpdater.applyAndRestart(file);
  }

  /// Now, then once a day, while "Check for updates" is on.
  void _scheduleUpdateChecks() {
    _updateTimer?.cancel();
    _updateTimer = null;
    if (!canCheckUpdates || !_desktopPrefs.checkUpdates) {
      _update = null;
      return;
    }
    unawaited(checkForUpdates());
    _updateTimer = Timer.periodic(
      const Duration(days: 1),
      (_) => unawaited(checkForUpdates()),
    );
  }

  Future<void> checkForUpdates() async {
    final update = await _updates?.check();
    if (update?.version != _update?.version) {
      _update = update;
      _downloadedUpdateFile = null;
      _updateProgress = null;
      _updateError = null;
      notifyListeners();
    }
  }

  /// "Not now": no reminder for this version (the next one shows again).
  Future<void> dismissUpdate() async {
    final version = _update?.version;
    if (version == null) return;
    _dismissedUpdate = version;
    notifyListeners();
    await _vault?.write(updateDismissedKey, version);
  }

  /// The built-in server (from the build configuration).
  ServerAddress get defaultServer =>
      ServerAddress(web: linkBase, relay: relayUrl);

  /// The server in use: the user's choice, or the built-in one.
  ServerAddress get server => _customServer ?? defaultServer;

  /// Whether the user chose another server (not possible in the browser,
  /// which always uses the server it was loaded from).
  bool get usesCustomServer => _customServer != null;
  bool get canChangeServer => persistent && !_rememberedInBrowser;

  /// Backups need Argon2id and a device that keeps the identity.
  bool get backupsAvailable =>
      persistent && SottoCrypto.passwordHashing(sodium) != null;

  Future<void> start() async {
    _setStage(AppStage.loading);
    try {
      _sodium ??= await SottoCrypto.init();
      if (!_lookedInBrowser && !_persistent && _browser.supported) {
        _lookedInBrowser = true;
        try {
          if (await _browser.open() case final remembered?) {
            _useBrowser(remembered);
          }
        } catch (e) {
          // Private windows may refuse storage: carry on, keeping nothing.
          debugPrint('Browser storage unavailable: $e');
        }
      }
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
    // The browser keeps one kind of PIN hash, remembered or not, so a PIN
    // set before "Remember me" still works after it.
    lock = AppLock(
      vault,
      persistent && !_browser.supported && sumo != null
          ? Argon2PinHasher(sumo)
          : SessionPinHasher(sodium, key: await _pinKey()),
    );
    contacts = ContactBook(vault);
    history = CallHistory(vault);
    devices = DeviceSettings(vault, _deviceLister());
    await lock.load();
    await contacts.load();
    await history.load();
    _profile = Profile.decode(await vault.read(profileKey));
    _desktopPrefs = DesktopPrefs.decode(await vault.read(desktopKey));
    _dismissedUpdate = await vault.read(updateDismissedKey);
    _customServer = canChangeServer
        ? ServerAddress.decode(await vault.read(serverKey))
        : null;
    if (_customServer case final custom?
        when formerDefaultHosts.contains(custom.web.host)) {
      _customServer = null;
      await vault.delete(serverKey);
    }
  }

  /// The browser's PIN-hash key, created once and kept with the secrets.
  Future<Uint8List> _pinKey() async {
    if (await _keystore.read(pinKeyName) case final stored?) {
      return b64Decode(stored);
    }
    final key = sodium.randombytes.buf(32);
    await _keystore.write(pinKeyName, b64Encode(key));
    return key;
  }

  /// Onboarding: creates the identity (if there is none yet) and saves the
  /// profile; in the browser, optionally remembers it.
  Future<void> completeOnboarding({
    required String name,
    String practice = '',
    bool rememberInBrowser = false,
  }) async {
    _identity ??= await IdentityStore(sodium, _keystore).loadOrCreate();
    await updateProfile(name: name, practice: practice);
    await _vault!.delete(legacyHostNameKey);
    if (rememberInBrowser && canRememberInBrowser) {
      await this.rememberInBrowser();
      return;
    }
    await _startCalls();
  }

  /// "Remember me on this browser": moves the identity and the data into
  /// the browser's storage, so reloading keeps the same links, contacts and
  /// history. Restarts the connection (not during a call).
  Future<void> rememberInBrowser() async {
    if (!canRememberInBrowser || _rememberedInBrowser) return;
    if (_calls?.call.active ?? false) {
      throw StateError('not during a call');
    }
    final stored = await _browser.create();
    await _moveTo(stored.secrets, stored.vaultFile);
    _useBrowser(stored);
    await start();
  }

  /// Forgets the identity in this browser: everything stored here is
  /// deleted; this tab keeps working until it is closed or reloaded.
  Future<void> forgetBrowser() async {
    if (!_rememberedInBrowser) return;
    final secrets = MemorySecretStore();
    final file = MemoryVaultFile();
    await _moveTo(secrets, file);
    await _browser.erase();
    _keystore = secrets;
    _openVaultFile = () async => file;
    _persistent = false;
    _rememberedInBrowser = false;
    await start();
  }

  void _useBrowser(BrowserStorage stored) {
    _keystore = stored.secrets;
    _openVaultFile = () async => stored.vaultFile;
    _persistent = true;
    _rememberedInBrowser = true;
  }

  /// Copies the identity, the PIN key and the vault's contents to other
  /// storage, and stops the calls (the caller restarts with [start]).
  Future<void> _moveTo(SecretStore secrets, VaultFile file) async {
    for (final key in [IdentityStore.masterSecretKey, pinKeyName]) {
      if (await _keystore.read(key) case final value?) {
        await secrets.write(key, value);
      }
    }
    final vault = await Vault.open(sodium: sodium, keys: secrets, file: file);
    await vault.replaceAll(_vault!.snapshot());
    vault.dispose();
    _stopCalls();
  }

  Future<void> updateProfile({
    required String name,
    String practice = '',
    String? avatar,
  }) async {
    final profile = _profile = Profile(
      name: name.trim(),
      practice: practice.trim(),
      avatar: avatar ?? _profile?.avatar,
    );
    await _vault!.write(profileKey, profile.encode());
    _calls?.publishGuestLinks();
    notifyListeners();
  }

  Future<void> updateAvatar(String? avatar) async {
    if (_profile == null) return;
    await updateProfile(
      name: _profile!.name,
      practice: _profile!.practice,
      avatar: avatar,
    );
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
        publicProfile: () => switch (_profile) {
          final p? => (name: p.name, organisation: p.practice, avatar: p.avatar),
          null => null,
        },
        sounds: AudioplayersOutput(),
      );
      await calls.start();
    }
    publishForTests('stage', 'ready');
    _setStage(AppStage.ready);
    _scheduleUpdateChecks();
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
    await ReceivedFileStore(sodium: sodium).eraseAll();
    _vault?.dispose();
    _vault = null;
    _profile = null;
    if (_rememberedInBrowser) {
      await _browser.erase();
      _keystore = MemorySecretStore();
      _openVaultFile = () async => MemoryVaultFile();
      _persistent = false;
      _rememberedInBrowser = false;
    }
    await start();
  }

  /// When the vault can't be opened: start with empty storage (the identity
  /// in the keystore is kept).
  Future<void> resetStorage() async {
    await Vault.erase(keys: _keystore, file: _vaultFile!);
    // The chat records that named these files are gone with the vault.
    await ReceivedFileStore(sodium: sodium).eraseAll();
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
    // A browser session that keeps nothing would lose its links on reload.
    setLeaveWarning(stage == AppStage.ready && !_persistent);
    notifyListeners();
  }

  @override
  void dispose() {
    _updater.cancel();
    _updateTimer?.cancel();
    _purgeTimer?.cancel();
    _calls?.dispose();
    _identity?.dispose();
    _vault?.dispose();
    super.dispose();
  }
}
