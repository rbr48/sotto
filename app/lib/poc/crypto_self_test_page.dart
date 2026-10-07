import 'package:flutter/material.dart';

import '../crypto/self_test.dart';
import '../crypto/sotto_crypto.dart';

/// Runs the crypto known-answer tests on this platform (`?selftest=1` on the
/// web). The result is shown on screen and in the browser tab title.
class CryptoSelfTestPage extends StatefulWidget {
  const CryptoSelfTestPage({super.key});

  @override
  State<CryptoSelfTestPage> createState() => _CryptoSelfTestPageState();
}

class _CryptoSelfTestPageState extends State<CryptoSelfTestPage> {
  List<String>? _failures;
  String? _error;

  @override
  void initState() {
    super.initState();
    SottoCrypto.init().then(
      (sodium) => setState(() => _failures = runCryptoSelfTest(sodium)),
      onError: (Object e) => setState(() => _error = '$e'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final failures = _failures;
    final String result;
    if (_error != null) {
      result = 'Self-test error: $_error';
    } else if (failures == null) {
      result = 'Self-test running…';
    } else if (failures.isEmpty) {
      result = 'Self-test passed';
    } else {
      result = 'Self-test failed: ${failures.join(', ')}';
    }
    return Title(
      title: 'Sotto · $result',
      color: Theme.of(context).colorScheme.primary,
      child: Scaffold(
        appBar: AppBar(title: const Text('Sotto · crypto self-test')),
        body: Center(child: Text(result, key: const Key('self-test-result'))),
      ),
    );
  }
}
