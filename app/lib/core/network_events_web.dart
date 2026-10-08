import 'package:web/web.dart' as web;

/// The browser says it is back online (e.g. after switching networks): a
/// hint to check connections now rather than at the next ping.
Stream<void> networkChanges() =>
    web.EventStreamProviders.onlineEvent.forTarget(web.window).map((_) {});
