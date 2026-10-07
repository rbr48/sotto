import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'poc/crypto_self_test_page.dart';
import 'poc/poc_call_page.dart';

void main() {
  runApp(const SottoApp());
}

class SottoApp extends StatelessWidget {
  const SottoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sotto',
      debugShowCheckedModeBanner: false,
      theme: SottoTheme.light(),
      darkTheme: SottoTheme.dark(),
      home: _webQuery['selftest'] == '1'
          ? const CryptoSelfTestPage()
          : PocCallPage(
              initialRoom: _webQuery['room'],
              autoJoin: _webQuery['join'] == '1',
            ),
    );
  }
}

/// Query parameters of the page URL in the web build, e.g. `?room=abc&join=1`.
Map<String, String> get _webQuery =>
    kIsWeb ? Uri.base.queryParameters : const <String, String>{};
