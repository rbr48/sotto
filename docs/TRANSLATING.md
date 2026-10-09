# Translating Sotto

Sotto is available in English, Bangla (বাংলা) and Arabic (العربية), though not
every screen is translated yet (see "Still to do" below). English is
the source language and the fallback: anything missing in another language
shows in English, never blank.

## Where the text lives

- `app/lib/core/l10n/arb/app_en.arb`: the source, one key per string.
- `app/lib/core/l10n/arb/app_bn.arb` and `app_ar.arb`: the translations, with
  the same keys.
- `app/l10n.yaml`: the settings. Running `flutter gen-l10n` (or any build)
  regenerates `app/lib/core/l10n/app_localizations*.dart`. Do not edit those by
  hand.

Use a key in code with `AppLocalizations.of(context).someKey`.

## Rules the tests enforce

- `app/test/core/l10n/translations_test.dart` fails if a language is missing a
  key, or has an empty value.
- Arabic is laid out right to left. Bangla uses the bundled Noto Sans Bengali
  font, because Roboto has no Bengali characters (see `app/assets/fonts/README.md`).
- Keep placeholders and numbers out of the translated text where possible, so
  the grammar of each language is not fixed by the English word order.

## Review status

**Every Bangla and Arabic string is a draft and has not been checked by a
native speaker.** Do not describe a language as verified until a native speaker
has reviewed it. Reviewers should check the translations against the app on a
phone, in both the light and dark theme.

## Still to do

- Convert the remaining screens. About 540 literal strings in about 80 files
  under `app/lib` still use English text directly. The largest groups are
  `app/`, `call/`, `guest/`, `contacts/` and `diagnostics/`. Navigation and the
  language picker are done.
- Website: add `lang` and `dir` attributes per page and a language switch.
- Store listings: add the `bn` and `ar` folders under
  `fastlane/metadata/android/` (title, descriptions, change log).
- Native speaker review of all drafted strings.
