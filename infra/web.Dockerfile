# Builds the Flutter web app and serves it, plus the relay, behind Caddy (automatic HTTPS).
# Build context: repository root.
FROM debian:bookworm-slim AS build
ARG FLUTTER_VERSION=3.47.6
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils unzip build-essential \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    | tar -xJ -C /opt \
 && git config --global --add safe.directory /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
RUN flutter config --no-analytics && flutter precache --web
WORKDIR /src
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./
RUN flutter build web --release --no-web-resources-cdn

# Emoji for the web app. The engine looks for characters its fonts lack in
# Noto Color Emoji, split into the files listed in infra/fonts/fallback.sha256,
# at fontFallbackBaseUrl (app/web/flutter_bootstrap.js: fonts/fallback/) plus
# the path from the engine's font_fallback_data.dart. They are fetched once
# here and checked, so browsers get them from this server, never from Google.
# Update the list when FLUTTER_VERSION changes (CI compares it with the engine).
FROM debian:bookworm-slim AS fonts
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /fonts
COPY infra/fonts/fallback.sha256 /tmp/fallback.sha256
RUN while read -r _ path; do \
      curl -fsSL --create-dirs -o "$path" "https://fonts.gstatic.com/s/$path"; \
    done </tmp/fallback.sha256 \
 && sha256sum -c /tmp/fallback.sha256

FROM caddy:2-alpine
COPY infra/caddy/Caddyfile /etc/caddy/Caddyfile
COPY --from=build /src/build/web /srv
COPY --from=fonts /fonts /srv/fonts/fallback
