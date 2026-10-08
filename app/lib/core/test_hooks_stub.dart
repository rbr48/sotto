/// Publishes a value for browser end-to-end tests. No-op outside the web.
void publishForTests(String name, String value) {}

/// Lets browser end-to-end tests call [action] as `window.<name>(argument)`.
/// No-op outside the web.
void registerTestAction(String name, void Function(String) action) {}
