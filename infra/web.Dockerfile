# Builds the Flutter web app and serves it, plus the relay, behind Caddy (automatic HTTPS).
# Build context: repository root.
FROM debian:bookworm-slim AS build
ARG FLUTTER_VERSION=3.47.6
# The SDK archive's SHA-256, from Flutter's release metadata (releases_linux.json).
# Update it together with FLUTTER_VERSION: the build stops if they don't match.
ARG FLUTTER_SHA256=f1631b9c2c8b3529323db412b0d1beacf4a748f8783b0d7cf599a8fd5f461675
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils unzip build-essential python3-fonttools python3-brotli \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/flutter.tar.xz "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
 && echo "${FLUTTER_SHA256}  /tmp/flutter.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/flutter.tar.xz -C /opt \
 && rm /tmp/flutter.tar.xz \
 && git config --global --add safe.directory /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
RUN flutter config --no-analytics && flutter precache --web
WORKDIR /src
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./
RUN flutter build web --release --no-web-resources-cdn
# Text fonts as WOFF2 (Roboto trimmed to the scripts the web build shows): a
# smaller first download. Native apps keep their TTF files. See the script.
COPY tools/web/compact_fonts.py tools/web/compact_fonts.py
RUN python3 tools/web/compact_fonts.py build/web

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
