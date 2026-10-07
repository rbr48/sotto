{{flutter_js}}
{{flutter_build_config}}

// Sotto loads nothing from third-party servers: the rendering engine is built
// with --no-web-resources-cdn, fonts are bundled, and fallback fonts (for
// characters Roboto lacks) are looked up on our own server instead of
// fonts.gstatic.com.
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: 'fonts/fallback/',
  },
});
