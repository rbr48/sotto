# Building and publishing releases

The `Release` workflow (`.github/workflows/release.yml`) builds Sotto for **Android**, **iOS**, **Windows** and **Linux** and publishes them on **GitHub Releases**.

| Platform | File | What it is |
|---|---|---|
| Android | `sotto-android.apk` | Release APK, signed with the project's release key |
| Android (Google Play) | `sotto-android-play.aab` | App bundle for the Play Console, same key, without Sotto's own update notice (see [APP_STORES.md](APP_STORES.md)) |
| iOS | `sotto-ios.ipa` | Sideloadable IPA (install via AltStore, SideStore, Sideloadly or TrollStore) |
| Windows | `sotto-windows-x64-setup.exe` | Installer (Inno Setup, `packaging/windows/sotto.iss`): per user, no administrator rights, into `%LOCALAPPDATA%\Programs\Sotto`, with a Start menu entry and an uninstaller. Installing a newer one over it updates Sotto and keeps contacts and history |
| Windows | `sotto-windows-x64.zip` | Portable bundle (`sotto.exe` and its files) |
| Linux | `sotto-linux-x86_64.AppImage` | One file that runs on most distributions (`chmod +x`, then run it) |
| Linux | `sotto-linux-amd64.deb` | Package for Ubuntu and Debian: `/opt/sotto`, a menu entry, `sotto` on the path (`sudo apt install ./sotto-linux-amd64.deb`) |
| Linux | `sotto-linux-x64.tar.gz` | Portable bundle (`sotto` and its libraries) |
| Checksums | `SHA256SUMS.txt` | SHA-256 of each file |

The Windows files are not code-signed until SignPath is set up ([CODE_SIGNING.md](CODE_SIGNING.md)); until then SmartScreen may warn about an unknown publisher ("More info", then "Run anyway"). The Linux builds are made on Ubuntu 22.04, so they run on Ubuntu 22.04 or newer, Debian 12 or newer, and other distributions of the same age. The AppImage tools are downloaded at pinned versions and checked by SHA-256 (`packaging/linux/fetch-appimage-tools.sh`). CI builds the installer, the .deb and the AppImage for every pull request, and installs the .deb.

Download links to `https://github.com/rbr48/sotto/releases/latest/download/<file>` always give the newest release (the app, the downloads page and the website use them).

The release notes start with the Android signing certificate's SHA-256 fingerprint, so anyone can check an APK (`apksigner verify --print-certs sotto-android.apk`).

## One-time setup: the Android release key

Android installs an update only if it is signed with **the same key** as the installed app. Every release must therefore use one permanent key. The workflow never makes one up: without the secrets below, the release stops.

1. On your own computer (needs Java's `keytool`), create the key. Choose a strong password when asked; use your organisation's country code:
   ```bash
   keytool -genkeypair -v -keystore sotto-release.jks -alias sotto -keyalg RSA -keysize 4096 \
     -validity 10000 -dname "CN=Sotto, O=Izhaan Intellect, C=BD"
   ```
2. **Back up `sotto-release.jks` and its password in two safe places** (for example an encrypted password manager and an offline drive). If they are lost, no update can ever be installed over the existing app; if they leak, someone else can sign "updates".
3. Encode it:
   - Linux/macOS: `base64 -w0 sotto-release.jks > sotto-release.jks.b64` (macOS: `base64 -i sotto-release.jks -o sotto-release.jks.b64`)
   - Windows (PowerShell): `[Convert]::ToBase64String([IO.File]::ReadAllBytes("sotto-release.jks")) > sotto-release.jks.b64`
4. In GitHub: **Settings → Secrets and variables → Actions → Secrets**, add:
   - `ANDROID_KEYSTORE_BASE64`: the contents of `sotto-release.jks.b64`
   - `ANDROID_KEYSTORE_PASSWORD`: the password
   - `ANDROID_KEY_ALIAS`: `sotto`
   - `ANDROID_KEY_PASSWORD`: the password (the same, unless you chose another for the key)
5. Recommended: pin the certificate. Print its fingerprint:
   ```bash
   keytool -list -v -keystore sotto-release.jks -alias sotto | grep 'SHA256:'
   ```
   and add it under **Settings → Secrets and variables → Actions → Variables** as `ANDROID_CERT_SHA256` (with or without colons). From then on a release signed with any other key fails.
6. Delete `sotto-release.jks.b64` from your computer once the secret is saved.

## Making a release

1. Raise the version in `app/pubspec.yaml`, both parts: `version: 0.1.2+3`. The part after `+` is Android's version code and must go up with every release, or Android refuses the update. Commit it to `main`, with the "What's new" text for the stores in `fastlane/metadata/android/en-US/changelogs/<version code>.txt` (500 bytes at most; the release stops without it).
2. Tag that commit and push the tag; the tag must match the version (`v0.1.2` for `0.1.2+3`), or the workflow stops:
   ```bash
   git tag v0.1.2
   git push origin v0.1.2
   ```
   Or run **Actions → Release → Run workflow** (leave the tag empty to use the version from `pubspec.yaml`; optionally publish as a draft or pre-release).
3. The workflow checks the version, then that the commit is on `main`, that CI passed for it on `main` (it waits up to 40 minutes for CI to finish) and that no release with this tag exists yet. Then it builds the three platforms, checks the APK's signature, and publishes the release with checksums and the certificate fingerprint.

A published release is never replaced: moving a tag to another commit makes the release stop. For a fix, raise the version and make a new release. (To redo a release on purpose, delete it on GitHub first.)

## Local builds

`flutter build apk --release` without `ANDROID_KEYSTORE_PATH` signs with the debug key: fine for testing, never for release. If `ANDROID_KEYSTORE_PATH` is set but the file is missing, the build fails instead of falling back.
