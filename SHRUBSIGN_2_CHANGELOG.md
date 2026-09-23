# ShrubSign 2.0 — source changes

This is a development source archive, not a precompiled or device-tested IPA.

## Implemented in this archive

- Native SwiftUI Home tab with current Core Data counts, imported/signed apps, repositories, certificate count, and expiration reminders.
- Real multi-file IPA import from Home via the existing file importer and extraction handler.
- HTTP(S) direct IPA URL download and import via the existing URLSession-backed download manager.
- Native navigation from Home to existing app discovery, individual repositories, signing library, Files, source management, certificates, and a source-add sheet.
- Search certificates by saved name while preserving the original certificate selection index.
- Sequential batch signing queue using the existing signing handler, visible progress, and per-app results. A failed app does not cancel remaining queued apps.
- ShrubLibrary website discovery link, clearly distinguished from native AltStore-compatible repository browsing.
- GitHub beta release checker using GitHub's public release API; build-commit comparison when both SHAs are available. Links go to actual release pages/assets, not a fake automatic install.
- Corrected certificate status text: a non-revoked database flag is **not** a live Apple revocation check.
- Optional Discord notifications skip successfully if `DISCORD_WEBHOOK` is missing, do not mark a successful IPA release as failed, and avoid verbose curl output.
- About screen uses the packaged logo asset and updated patch notes.

## Working functionality retained from the uploaded source

- Native repository parsing, search, app detail, download flow.
- Multi-file IPA import and bulk-signing from Library edit mode.
- Existing signing engine, certificate import/details, IPA export, Files, signing settings.
- Existing `shrubsign://` and legacy `ksign://` links.

## Not implemented or validated by this archive

- Full automatic import of ShrubLibrary's whole website catalog: the attached source contains no published catalog API contract. Users can still add compatible sources natively.
- A complete redesign of every pre-existing signing/certificate screen or an entirely new signing engine.
- Xcode compilation or functional testing on a real iOS device: requires GitHub Actions and device verification.

## Updating a Codespace safely

Unpack only the root project files from this ZIP into your current repository. It deliberately retains the old app files and licenses. Keep a backup of your working beta before installing a new build. Never commit private signing certificates or passwords.
