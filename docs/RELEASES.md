# Building and Publishing Releases

Sotto automated release builds produce signed application packages for **Android**, **Windows**, and **Linux**, and publishes them directly to **GitHub Releases**.

## Release Assets

Every release produces:

| Platform | Format | Asset Name | Description |
|---|---|---|---|
| **Android** | APK | `sotto-android.apk` | Signed release APK (arm64-v8a, armeabi-v7a, x86_64) |
| **Windows** | ZIP | `sotto-windows-x64.zip` | Standalone portable Windows release bundle (`sotto.exe` + assets) |
| **Linux** | tar.gz | `sotto-linux-x64.tar.gz` | Standalone portable Linux release bundle (`sotto` + libraries) |
| **Checksums** | TXT | `SHA256SUMS.txt` | SHA-256 cryptographic hashes of all binaries |

---

## How to Trigger a Release

### Method 1: Git Tag (Recommended)

1. Ensure the version in `app/pubspec.yaml` is updated (e.g., `version: 0.1.0+1`).
2. Create and push a tag starting with `v`:
   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```
3. GitHub Actions will automatically start the `Release` workflow, build all three platforms in parallel, and publish the release with release notes.

### Method 2: Manual Trigger via GitHub Actions

1. Go to **Actions** → **Release** in your GitHub repository.
2. Click **Run workflow**.
3. (Optional) Provide a custom tag name (e.g. `v0.1.0`), or leave blank to automatically read the version from `app/pubspec.yaml`.
4. (Optional) Check "Publish as draft" or "Publish as pre-release".
5. Click **Run workflow**.

---

## Android Signing Configuration

The release workflow in `.github/workflows/release.yml` and `app/android/app/build.gradle.kts` supports two signing modes:

### 1. Default Mode (Zero-Config Self-Signed Release)
If no repository secrets are provided, the workflow generates a valid self-signed release keystore on the fly (`RSA 2048`, validity 10,000 days). This produces a fully signed release APK with APK Signature Scheme v1, v2, and v3 enabled.

### 2. Custom Production Keystore (Optional)
To sign with your organisation's official production keystore:

1. Generate or locate your `.jks` / `.keystore` file:
   ```bash
   keytool -genkey -v -keystore sotto-release.jks -alias sotto -keyalg RSA -keysize 2048 -validity 10000
   ```
2. Convert the keystore file to base64:
   * **Linux/macOS:**
     ```bash
     base64 -w 0 sotto-release.jks
     ```
   * **Windows (PowerShell):**
     ```powershell
     [Convert]::ToBase64String([IO.File]::ReadAllBytes("sotto-release.jks"))
     ```
3. In your GitHub repository, navigate to **Settings** → **Secrets and variables** → **Actions**, and add the following repository secrets:
   - `ANDROID_KEYSTORE_BASE64`: The full base64 string from step 2
   - `ANDROID_KEYSTORE_PASSWORD`: The keystore password
   - `ANDROID_KEY_ALIAS`: The key alias (e.g., `sotto`)
   - `ANDROID_KEY_PASSWORD`: The key password
