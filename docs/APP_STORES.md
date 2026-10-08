# Google Play and F-Droid (IzzyOnDroid)

Each GitHub release has everything the stores need:

| Store | File | Notes |
|---|---|---|
| Google Play | `sotto-android-play.aab` | App bundle without Sotto's own update notice (Play delivers updates). Signed with the release key. |
| IzzyOnDroid (F-Droid client) | `sotto-android.apk` | The same signed APK as on GitHub. |

The listing (title, descriptions, icon, feature graphic, eight phone screenshots, change log) is in
[`fastlane/metadata/android/en-US/`](../fastlane/metadata/android/en-US). Both stores read this layout.
Add `changelogs/<versionCode>.txt` (500 characters at most) for each release; the version code is the
number after `+` in `app/pubspec.yaml`.

Everything below has to be done by the account owner, on the store's website.

## Google Play

### Once

1. **Developer account.** Create one at <https://play.google.com/console>. It costs USD 25 once and
   needs identity verification, which can take a few days.
   - A *personal* account must run a closed test with at least 12 testers for 14 days before the app
     can go public.
   - An *organisation* account (it needs a D-U-N-S number) can publish directly.
2. **Create the app.** Use the name "Sotto: private calls", default language English, type App,
   and Free.
3. **App signing.** Choose *Use a different key / export and upload a key from Java keystore*, and
   upload the **existing release key** with Google's PEPK tool.
   - Play then signs with the same key as the GitHub APK, so people can move between the two
     without uninstalling.
   - If you let Google create a new key instead, a Play install and a GitHub install can't update
     each other.
4. **Store listing.** Copy the files from `fastlane/metadata/android/en-US/`:
   - `title.txt` → App name;
   - `short_description.txt` → Short description;
   - `full_description.txt` → Full description;
   - `images/icon.png` → App icon (512 × 512);
   - `images/featureGraphic.png` → Feature graphic (1024 × 500);
   - `images/phoneScreenshots/*.png` → Phone screenshots.
   - Category: *Communication*. Contact e-mail: hello@sottocall.com.
   - Privacy policy: <https://call.sottocall.com/privacy.html>.
5. **App content** (Policy → App content). Prepared answers:
   - **Ads:** no ads.
   - **Target audience:** 18 and over. Sotto is a professional tool and is not designed for children.
   - **Content rating questionnaire:** category *Communication*. It allows users to interact with each
     other and to share their names; no violence, gambling and so on. Expected result: Everyone /
     PEGI 3, with "Users interact".
   - **News app:** no. **Government app:** no. **Financial features:** none. **Health app:** no.
     Practitioners use it, but it handles no health data.
   - **Data safety:**
     - *Does your app collect or share user data?* **No.**
       - Call content and the call set-up messages, including names, are end-to-end encrypted.
         Google's definitions exempt end-to-end encrypted data from "collected".
       - The relay processes IP addresses and public keys only briefly, in memory, to connect calls
         (ephemeral processing), and never stores them.
       - Contacts, history and notes never leave the device.
     - *Is data encrypted in transit?* Yes.
     - *Can users request deletion?* Nothing is stored on the server. Data on the device is deleted
       with *Settings → Erase Sotto from this device*, or by uninstalling.
   - **Permissions declarations.** Play asks about these because Sotto doesn't use Google's push
     service (FCM):
     - `FOREGROUND_SERVICE_SPECIAL_USE`: "Keeps the encrypted connection to the call relay open while
       the user waits for calls, so incoming calls ring. Sotto does not use Firebase Cloud Messaging:
       call notifications never pass through Google. The user can turn this off in Settings."
     - `FOREGROUND_SERVICE_MICROPHONE` / `FOREGROUND_SERVICE_CAMERA`: "Keeps an active call's
       microphone and camera working when the user leaves the app during the call."
     - `USE_FULL_SCREEN_INTENT`: "Calling app: shows incoming calls full-screen, like the phone app."
       Choose the *Calling* use case.
     - `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: "Voice and video calling app with its own real-time
       connection (no FCM). Without the exemption, Android's battery saver stops the connection and
       calls are missed." This matches Play's accepted use case for apps whose core function needs a
       persistent connection that can't use FCM.

### Every release

1. Run the release workflow as usual. Then download `sotto-android-play.aab` from the GitHub release.
2. In the Play Console, go to *Production* (or *Testing → Closed testing*), choose *Create new
   release*, and upload the `.aab`.
3. Paste the release's `changelogs/<versionCode>.txt` as the release notes, then *Review* →
   *Start rollout*. Google's review takes from a few hours to a few days.

## F-Droid: through IzzyOnDroid

- **Why not the main F-Droid repository?** F-Droid builds every app from source on its own servers.
  Sotto's calling library (flutter_webrtc) ships a prebuilt WebRTC binary. F-Droid's main repository
  doesn't accept prebuilt libraries, and building WebRTC from source there would be a large project of
  its own.
- **IzzyOnDroid** is the largest F-Droid-compatible repository. F-Droid clients such as Droid-ify and
  Neo Store include it, and anyone can add it to the F-Droid app.
  - It distributes the APK from the GitHub releases, signed with your key, and reads the
    `fastlane/metadata` folder above.
  - It scans every APK for trackers and non-free components. Sotto has none.

To get listed:

1. Open a request at <https://gitlab.com/IzzyOnDroid/repo/-/issues> with the *app inclusion* template.
   Give it:
   - the source code: <https://github.com/rbr48/sotto>;
   - the package name `com.izhaanintellect.sotto`;
   - the APK file name: `sotto-android.apk` from the GitHub releases;
   - the license: AGPL-3.0-or-later.
2. Answer the maintainer's questions in the issue. Usually it's listed within days, and new GitHub
   releases are picked up automatically.

**Obtainium** works today without any listing. People add `https://github.com/rbr48/sotto`, and it
installs and updates the APK straight from the GitHub releases.
