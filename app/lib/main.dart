import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'call/call_controller.dart';
import 'call/ui/call_page.dart';
import 'core/config.dart';
import 'core/theme.dart';
import 'diagnostics/crypto_self_test_page.dart';
import 'guest/guest_link.dart';
import 'guest/ui/guest_page.dart';

void main() {
  // The app has a single screen; keep Flutter's router away from the URL so
  // the guest link payload after `#` is left alone.
  setUrlStrategy(null);
  runApp(const SottoApp());
}

class SottoApp extends StatefulWidget {
  const SottoApp({super.key});

  @override
  State<SottoApp> createState() => _SottoAppState();
}

class _SottoAppState extends State<SottoApp> {
  final _selfTest = _webQuery['selftest'] == '1';
  late final CallController? _controller = _selfTest
      ? null
      : (CallController(
          relayUrl: SottoConfig.relayUrl,
          linkBase: SottoConfig.linkBase,
          guestLinkPayload: _guestPayload,
        )..start());

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sotto',
      debugShowCheckedModeBanner: false,
      theme: SottoTheme.light(),
      darkTheme: SottoTheme.dark(),
      home: switch (_controller) {
        null => const CryptoSelfTestPage(),
        final controller when controller.isGuest => GuestPage(
          controller: controller,
        ),
        final controller => CallPage(
          controller: controller,
          autoCallLink: _webQuery['call'] == null ? null : Uri.base.toString(),
        ),
      },
    );
  }
}

/// Query parameters of the page URL in the web build, e.g. `?call=<code>`.
Map<String, String> get _webQuery =>
    kIsWeb ? Uri.base.queryParameters : const <String, String>{};

/// The guest link payload when the web app was opened from `…/#g=<payload>`.
String? get _guestPayload {
  if (!kIsWeb) return null;
  final fragment = Uri.base.fragment;
  return fragment.startsWith('${GuestLink.fragmentKey}=')
      ? GuestLink.payloadOf(fragment)
      : null;
}
