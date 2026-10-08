{{flutter_js}}
{{flutter_build_config}}

// No service worker: it would keep serving an old version after an update.
// Remove one an earlier version may have installed.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.getRegistrations()
    .then((all) => all.forEach((registration) => registration.unregister()))
    .catch(() => {});
}

// Sotto loads nothing from third-party servers: the rendering engine is built
// with --no-web-resources-cdn, fonts are bundled, and fallback fonts (for
// characters Roboto lacks) are looked up on our own server instead of
// fonts.gstatic.com.
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: 'fonts/fallback/',
  },
});
