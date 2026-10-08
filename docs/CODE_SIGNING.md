# Code signing for Windows

Without a code signature, Windows SmartScreen warns about an "unknown publisher" when people run
the installer. The release workflow can sign `sotto.exe` and `sotto-windows-x64-setup.exe` through
**SignPath**. SignPath Foundation gives open-source projects a code-signing certificate and signing
service free of charge, from any country.

Until it is set up, releases build exactly as before, unsigned.

## Set it up once

1. **Apply** at <https://signpath.org/apply>, the SignPath Foundation open-source program.
   - Give the repository <https://github.com/rbr48/sotto> and the license, AGPL-3.0-or-later.
   - They check that the project is open source, maintained, and built by GitHub Actions from this
     public repository. They may ask for a short description and a project homepage:
     <https://sottocall.com>.
   - The certificate is issued in the name "SignPath Foundation" for your project. That is how their
     program works, and SmartScreen trusts it.
2. In SignPath, once approved:
   - **Project:** create one with the slug `sotto`.
   - **Trusted build system:** link GitHub.com to the project, so only builds from this repository
     can be signed.
   - **Artifact configurations:** create two, with exactly these slugs, by pasting the files from
     this repository:
     - `windows-app` ← `packaging/windows/signpath/windows-app.xml`
     - `windows-installer` ← `packaging/windows/signpath/windows-installer.xml`
   - **Signing policy:** use the slug `release-signing`. SignPath Foundation usually needs someone to
     approve each signing request; approve it in SignPath while the release runs.
   - **API token:** create one for a CI user that is a *submitter* on the policy.
3. In GitHub, under *Settings → Secrets and variables → Actions*:
   - **Variable** `SIGNPATH_ORGANIZATION_ID`: your SignPath organisation ID.
   - **Secret** `SIGNPATH_API_TOKEN`: the API token.
   - Only if your slugs differ from the ones above: the variables `SIGNPATH_PROJECT_SLUG` and
     `SIGNPATH_SIGNING_POLICY`.

The next release then signs the app, builds the installer from the signed app, signs the installer,
and says so in the release notes. Every signature is visible under the file's *Properties → Digital
Signatures*.

## Other options

- **A standard OV code-signing certificate** costs about USD 200–400 a year from Sectigo, DigiCert
  and others. Since 2023 the key must live on a hardware token or in a cloud HSM, so the workflow
  would need that vendor's signing tool instead of SignPath.
- **Azure Trusted Signing** costs about USD 10 a month, but is only available to organisations in
  the US, Canada, the EU and the UK, and to individuals in the US and Canada.

SmartScreen reputation builds up per certificate. Even signed files can show a milder warning for a
short while after the first releases.
