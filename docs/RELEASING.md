# Releasing Cellar

## Unsigned prerelease

Unsigned evaluation builds use a hyphenated prerelease tag such as
`v2.2.3-beta.1`. Build them locally with:

```bash
./script/package_unsigned_prerelease.sh
```

Publish both files from `dist/`, mark the GitHub release as a prerelease, and state
clearly that the app is neither Developer ID signed nor notarized. Hyphenated tags
skip the signed release workflow. Never rename an unsigned artifact to
`Cellar-macOS.zip`; that filename is reserved for verified signed releases.

The stable-channel unsigned preview exception uses the `v2.2.3` tag and the
release title `Cellar 2.2.3 Unsigned Preview`. It keeps the asset name
`Cellar-macOS-unsigned.zip`, and the release notes must repeat that the app is
not Developer ID signed or notarized. The signed release workflow is skipped unless
the repository variable `CELLAR_SIGNED_RELEASE` is set to `true`.
Cellar public binaries must be signed with a **Developer ID Application**
certificate, notarized by Apple, stapled, and accepted by Gatekeeper. An ad hoc
or Apple Development signature is not a public release.

## Prerequisites

- A paid Apple Developer Program membership
- A Developer ID Application certificate and private key in the signing keychain
- App Store Connect API notarization credentials, or a saved `notarytool`
  keychain profile
- A stable Xcode toolchain that supports the project

Confirm the signing identity:

```bash
security find-identity -v -p codesigning
```

The identity must begin with `Developer ID Application:`.

## Local release

With a saved `notarytool` profile:

```bash
./script/package_release.sh \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile "cellar-notary"
```

Or use an App Store Connect API key:

```bash
./script/package_release.sh \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-key "/path/to/AuthKey_KEYID.p8" \
  --notary-key-id "KEYID" \
  --notary-issuer "ISSUER_UUID"
```

The script builds a Universal app (`arm64` and `x86_64`), enables Hardened
Runtime, signs it, waits for notarization, staples the ticket, runs Gatekeeper
assessment, and creates a ZIP plus SHA-256 checksum in `dist/`.

## GitHub release

The release workflow runs for version tags matching `v*` when the repository
variable `CELLAR_SIGNED_RELEASE` is `true`. Configure these
repository secrets before creating a tag:

- `APPLE_DEVELOPER_ID_P12_BASE64`
- `APPLE_DEVELOPER_ID_P12_PASSWORD`
- `APPLE_DEVELOPER_ID_IDENTITY`
- `APPLE_NOTARY_PRIVATE_KEY_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

The signed workflow does not publish an unsigned fallback. It creates or updates the
GitHub Release only after signing, notarization, stapling, Gatekeeper assessment,
and checksum generation all succeed.

Before tagging, confirm that the tag and Xcode `MARKETING_VERSION` match:

```bash
git tag v2.2.3
git push origin v2.2.3
```

After publishing, test the ZIP on a Mac that does not have the development
certificate installed, then submit or update the Homebrew Cask.
