import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Publishes a value as a `data-sotto-<name>` attribute on `<html>`, so the
/// browser end-to-end tests can read things drawn on the canvas (like the call
/// link). Only public information is ever published.
void publishForTests(String name, String value) {
  web.document.documentElement?.setAttribute('data-sotto-$name', value);
}

/// Test builds only (`--dart-define=SOTTO_TEST_HOOKS=true`): lets the browser
/// end-to-end tests call [action] as `window.<name>(argument)`, e.g. to
/// simulate a weak upload. Release builds never register anything.
const testHooks = bool.fromEnvironment('SOTTO_TEST_HOOKS');

void registerTestAction(String name, void Function(String) action) {
  if (!testHooks) return;
  web.window.setProperty(
    name.toJS,
    ((JSString argument) => action(argument.toDart)).toJS,
  );
}
