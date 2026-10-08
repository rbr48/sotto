import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'test_hooks.dart';

/// While a browser session keeps nothing, reloading or closing the page
/// would end it and its links: the browser asks first.
void setLeaveWarning(bool on) {
  web.window.onbeforeunload = on ? _warn : null;
  publishForTests('leave-warning', '$on');
}

final JSFunction _warn = (web.Event event) {
  event.preventDefault();
  // Older browsers need returnValue set as well.
  (event as web.BeforeUnloadEvent).returnValue = '';
}.toJS;
