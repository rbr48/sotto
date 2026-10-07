import 'package:web/web.dart' as web;

/// Publishes a value as a `data-sotto-<name>` attribute on `<html>`, so the
/// browser end-to-end tests can read things drawn on the canvas (like the call
/// link). Only public information is ever published.
void publishForTests(String name, String value) {
  web.document.documentElement?.setAttribute('data-sotto-$name', value);
}
