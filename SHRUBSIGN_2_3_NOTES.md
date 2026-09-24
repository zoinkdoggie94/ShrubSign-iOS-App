# ShrubSign 2.3 — Catalog reliability and native UI

This update is based on the user's latest uploaded source archive, not a new signer engine.

## Implemented

- Correct app marketing version and repository metadata to 2.3.0.
- Use the already-deployed `https://shrublibrary.pages.dev/proxy?url=...` as a fallback for repository data; for two observed TLS-problem hosts, try it first. JSON text-repair mode is attempted only for malformed proxied JSON, not for normal valid repositories. No TLS verification is disabled. The source URL, app identity, and IPA download URLs are not replaced with proxy URLs.
- Normalize inconsistent optional app/repository metadata and relative URLs without making up app download links; distinguish marketplace-only and actually empty sources from parser failures.
- Prepare catalog app-entry arrays off the UI thread, reduce simultaneous repo loads to two, cache entries, and cancel stale search workers.
- Show real repository icons where provided (fallback to a generic symbol), plus a compact progress panel and clearer source status. Image requests may fall back to `/proxy?url=...&image=1` after a direct loading error.
- Keep signing engine, existing app files, certificate storage, imported repositories, and attribution untouched.

## Testing and limits

The catalog normalizer has an offline smoke test at `scripts/catalog_normalizer_smoke.swift`. Swift source parsing and JSON/plist checks are possible outside macOS, but full Xcode compilation and iPad-specific performance testing must occur in GitHub Actions and on an actual device. Individual third-party sources may not supply an IPA, may be down, or may still use a format unsupported by the existing repository model; a proxy cannot guarantee their availability.

## Codespaces deployment

Upload the complete source ZIP to the repository root in Codespaces, then extract and copy the top-level `ShrubSign-iOS-App-main` folder contents into your repository. Stage and commit the source files while excluding any uploaded ZIP/IPA.
