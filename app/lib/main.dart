import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_controller.dart';
import 'app/ui/app_root.dart';
import 'call/call_controller.dart';
import 'call/ui/quick_call_page.dart';
import 'contacts/contact_link.dart';
import 'core/config.dart';
import 'core/l10n/app_localizations.dart';
import 'core/l10n/language.dart';
import 'core/theme.dart';
import 'desktop/autostart.dart';
import 'desktop/desktop_integration.dart';
import 'desktop/single_instance.dart';
import 'diagnostics/crypto_self_test_page.dart';
import 'guest/guest_link.dart';
import 'guest/ui/guest_page.dart';
import 'sound/call_sounds.dart';

Future<void> main(List<String> args) async {
  // Keep Flutter's router away from the URL so link payloads after `#` are
  // left alone.
  setUrlStrategy(null);
  // Desktop plugins (window, tray) talk to the engine before the first frame.
  WidgetsFlutterBinding.ensureInitialized();
  // One Sotto per desktop session: a second start shows the first.
  if (isDesktop) {
    try {
      final dir = await getApplicationSupportDirectory();
      if (await SingleInstance.claim(dir) == null) exit(0);
    } catch (e) {
      debugPrint('Single-instance check skipped: $e');
    }
  }
  await loadAppLanguage();
  runApp(SottoApp(startHidden: args.contains(Autostart.hiddenFlag)));
}

/// What the app was opened for.
enum _Mode { selfTest, guest, quickCall, app }

class SottoApp extends StatefulWidget {
  const SottoApp({super.key, this.startHidden = false});

  /// Desktop: started at login, so it opens in the tray.
  final bool startHidden;

  @override
  State<SottoApp> createState() => _SottoAppState();
}

class _SottoAppState extends State<SottoApp> {
  late final _Mode _mode = switch (kIsWeb) {
    true when Uri.base.queryParameters['selftest'] == '1' => _Mode.selfTest,
    true when _fragment(GuestLink.fragmentKey) => _Mode.guest,
    true
        when Uri.base.queryParameters.containsKey('call') ||
            _fragment(ContactLink.fragmentKey) =>
      _Mode.quickCall,
    _ => _Mode.app,
  };

  /// Guest pages and browser quick calls: a temporary identity, nothing
  /// stored.
  late final CallController? _calls = switch (_mode) {
    _Mode.guest || _Mode.quickCall => CallController(
      relayUrl: SottoConfig.relayUrl,
      linkBase: SottoConfig.linkBase,
      guestLinkPayload: _mode == _Mode.guest
          ? GuestLink.payloadOf(Uri.base.fragment)
          : null,
      sounds: AudioplayersOutput(),
    )..start(),
    _ => null,
  };

  late final AppController? _app = _mode == _Mode.app
      ? (AppController(
          relayUrl: SottoConfig.relayUrl,
          linkBase: SottoConfig.linkBase,
        )..start())
      : null;

  @override
  void dispose() {
    _calls?.dispose();
    _app?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: appLanguage,
    builder: (context, language, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      // Null follows the device. Arabic mirrors the layout (right to left)
      // through the Material localisations below.
      locale: language.locale,
      supportedLocales: AppLanguage.supported,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      onGenerateTitle: (context) => AppLocalizations.of(context).appName,
      theme: SottoTheme.light(),
      darkTheme: SottoTheme.dark(),
      home: switch (_mode) {
        _Mode.selfTest => const CryptoSelfTestPage(),
        _Mode.guest => GuestPage(controller: _calls!),
        _Mode.quickCall => QuickCallPage(
          controller: _calls!,
          link: Uri.base.toString(),
          dialImmediately: Uri.base.queryParameters.containsKey('call'),
        ),
        _Mode.app => AppRoot(app: _app!, startHidden: widget.startHidden),
      },
    ),
  );
}

/// Whether the page URL's fragment carries `<key>=…` (web only).
bool _fragment(String key) =>
    kIsWeb &&
    Uri.base.fragment.split('&').any((part) => part.startsWith('$key='));
