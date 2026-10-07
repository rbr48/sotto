import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'call/call_controller.dart';
import 'call/ui/call_page.dart';
import 'core/config.dart';
import 'core/theme.dart';
import 'diagnostics/crypto_self_test_page.dart';

void main() {
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
      home: _controller == null
          ? const CryptoSelfTestPage()
          : CallPage(
              controller: _controller,
              autoCallLink: _webQuery['call'] == null
                  ? null
                  : Uri.base.toString(),
            ),
    );
  }
}

/// Query parameters of the page URL in the web build, e.g. `?call=<code>`.
Map<String, String> get _webQuery =>
    kIsWeb ? Uri.base.queryParameters : const <String, String>{};
