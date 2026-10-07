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
RUN flutter build web --release

FROM caddy:2-alpine
COPY infra/caddy/Caddyfile /etc/caddy/Caddyfile
COPY --from=build /src/build/web /srv
