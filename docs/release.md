# Building and releasing GitBonsai

## Bundles

| Command | Bundle | Bundle id | Use |
|---|---|---|---|
| `scripts/make-app-bundle.sh` | `.build/app/GitBonsai Dev.app` | `app.gitbonsai.dev` | trying out a branch next to an installed release |
| `scripts/make-app-bundle.sh --release` | `.build/app/GitBonsai.app` | `app.gitbonsai` | releases only |

The bundle id is also the defaults domain, so the dev bundle keeps its own open tabs, recent repositories and settings and shows as "GitBonsai Dev" in the Dock. Both bundles open folders from Finder, from a drop on the Dock icon and with `open -a <bundle> <folder>`.

Version and build number go into `Info.plist`:

- `CFBundleShortVersionString`: `GITBONSAI_VERSION`, else the version tag on HEAD (`0.2.0`, no `v` prefix), else the latest version tag, else `0.1`; an earlier `v0.1.0`-style tag counts only where no plain one exists.
- `CFBundleVersion`: `GITBONSAI_BUILD`, else the commit count of HEAD (monotonic on `main`).

## Signing and notarization

Without credentials everything is signed ad hoc: the app runs on the machine that built it, and a downloaded copy needs "Open Anyway" in System Settings › Privacy & Security. With credentials the scripts sign with Developer ID, hardened runtime and a secure timestamp, then notarize and staple.

### GitHub secrets

| Secret | Content |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | base64 of the exported Developer ID Application certificate with its private key (`.p12`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the password chosen at export |
| `NOTARY_API_KEY_P8` | content of the App Store Connect API key file `AuthKey_<id>.p8` (preferred) |
| `NOTARY_API_KEY_ID` | that key's id |
| `NOTARY_API_ISSUER_ID` | the issuer id shown above the key list |
| `NOTARY_APPLE_ID`, `NOTARY_APP_PASSWORD`, `APPLE_TEAM_ID` | alternative to the API key: Apple ID, app-specific password, team id |

Without the certificate secrets the release workflow builds an ad-hoc-signed artifact and says so in a warning and in the release notes; with the certificate but no notary secrets it signs without notarizing.

### Creating the credentials

1. **Developer ID certificate** (needs the Account Holder role in the Apple Developer account): Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application. Then in Keychain Access, under My Certificates, right-click "Developer ID Application: <name> (<team>)" › Export… as `.p12` with a strong password. Store it: `base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_P12` and `gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD`.
2. **Notary API key**: App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys › +, access "Developer". Download `AuthKey_<id>.p8` (only once), then `gh secret set NOTARY_API_KEY_P8 < AuthKey_<id>.p8`, `gh secret set NOTARY_API_KEY_ID`, `gh secret set NOTARY_API_ISSUER_ID`.
3. **Apple ID alternative**: create an app-specific password at account.apple.com › Sign-In and Security, and set `NOTARY_APPLE_ID`, `NOTARY_APP_PASSWORD` and `APPLE_TEAM_ID` (the team id is in the membership details).

Switching from a personal to a company account only changes these secrets; the bundle ids stay.

## Cutting a release

1. On `main`, with CI green: `git tag -a 0.2.0 -m "GitBonsai 0.2.0"` and `git push origin refs/tags/0.2.0:refs/tags/0.2.0`.
2. The Release workflow builds, signs, notarizes and staples, uploads `GitBonsai-0.2.0.dmg` and `.zip` as the workflow artifact `GitBonsai` and creates a **draft** GitHub release with generated notes.
3. Check the draft (download, open, `spctl --assess --type execute -v GitBonsai.app` says "Notarized Developer ID"), edit the notes, publish.

"Run workflow" on the Release workflow builds the same artifact from any branch without a release; its version field overrides the tag-derived version.

## Building and signing locally

```bash
scripts/make-app-bundle.sh --release
scripts/package-release.sh .build/app/GitBonsai.app
```

For a signed and notarized local build, store the notary credentials once in the keychain and pass the identity:

```bash
xcrun notarytool store-credentials gitbonsai-notary --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer>
GITBONSAI_SIGN_IDENTITY="Developer ID Application: <name> (<team>)" scripts/make-app-bundle.sh --release
GITBONSAI_SIGN_IDENTITY="Developer ID Application: <name> (<team>)" NOTARY_KEYCHAIN_PROFILE=gitbonsai-notary scripts/package-release.sh .build/app/GitBonsai.app
```

`package-release.sh` also reads the API-key and Apple-ID variables the workflow uses (`NOTARY_KEY_PATH`/`NOTARY_KEY_ID`/`NOTARY_ISSUER` or `NOTARY_APPLE_ID`/`NOTARY_PASSWORD`/`NOTARY_TEAM_ID`).

## CI

`.github/workflows/ci.yml` runs on pushes to `main`, pull requests and manually: debug and release builds with warnings as errors, then `swift test`. Both workflows run on GitHub's `xcode-27` image (arm64, generally available since October 2026; the `xcode-27-xlarge` label is the larger, separately billed size) and select `/Applications/Xcode_27.2.app` explicitly, because the code needs Swift 6.4 and the `macos-26` image's Xcode 26 cannot compile it (for example async closures passed where Xcode 26 expects synchronous ones). Each run prints `xcodebuild -version` and `swift --version` first. Keep the selected Xcode in step with the one used locally; when the image drops 27.2 or the local Xcode moves on, update the path in both workflows. `.github/actionlint.yaml` declares the label because actionlint does not know it yet. Fallback if the image becomes unavailable or unreliable: go back to `macos-26` and make the code compile with Xcode 26's Swift, then build locally with that toolchain to confirm. macOS minutes on a private repository count ten times against the plan's included minutes (and cost about ten times a Linux minute beyond them), so the workflows cancel superseded runs and run only on `main`, pull requests and tags.

## Next step

Sparkle auto-update (appcast, EdDSA key as another secret, published from the release workflow) is not set up yet.
