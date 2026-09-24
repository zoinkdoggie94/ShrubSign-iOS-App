> **ShrubSign 2.3 catalog maintenance:** The native ShrubLibrary catalog now tries direct repository fetches with a fallback to the existing ShrubLibrary /proxy endpoint, normalizes supported inconsistent optional metadata, displays repository icons when available, and uses a more compact progress view. Marketplace-only sources without IPA downloads remain unsupported. Live results depend on source availability and proxy deployment. See `SHRUBSIGN_2_3_NOTES.md`.

<p align="center">
  <img src="https://ipa-and-dns-stuff.pages.dev/icons/shrubhub.png" width="160" alt="ShrubSign icon">
</p>

# ShrubSign

**ShrubSign** is ShrubHub's fork of [Ksign](https://github.com/nyasami/Ksign), an iOS app for signing and managing IPA files on supported devices.

## ShrubSign 2.1 source update

- **Native ShrubLibrary catalog**: reads `https://shrublibrary.pages.dev/repos.txt` only when the catalog is opened, validates and fetches independent repositories with a three-request limit, stores local source caches, reports individual failures, and supports searching while sources load. Repository attribution and duplicate app listings remain separate.
- **Custom repositories**: the existing custom repository manager and parser are retained; imported sources also appear in the unified catalog without loading an identical directory URL twice.
- **App details and downloads**: open each app's actual repository metadata, screenshots when provided, version history, and IPA download; the existing import/signing engine is preserved. Download screens now show validation failures and retry controls.
- **Signing presets**: save, rename, delete, set as default, and apply reusable options from individual or batch signing. Presets reference certificate IDs, never private keys/passwords, and do not copy app-specific names or bundle IDs.
- **Certificate & IPA details**: searchable/filterable/sortable identities, preferred identity ID persistence, expiration and revocation wording, source links, and extracted app size in the native info screen.
- **Polish and reliability**: improved screenshot decoding, repository fetch completion, zero/unknown-size progress wording, safer download filenames, ZIP header/HTTP validation, improved mobile layouts, and more useful GitHub build-error logs.

This is **source code**, not a precompiled or device-verified IPA. Build with GitHub Actions/Xcode, then test on your iPad. Third-party repository listings and IPAs are not verified for safety merely by appearing in the catalog. See [SHRUBSIGN_2_1_NOTES.md](SHRUBSIGN_2_1_NOTES.md) for testing steps and known limits.

## Building

Clone recursively, then build with Xcode or run:

```sh
make
```

The makefile creates `packages/ShrubSign.ipa`. The GitHub Actions beta workflow also publishes `ShrubSign.ipa` when it runs on `main`.

## Upstream & credits

ShrubSign is based on **Ksign** by Nyasami/Nagata Asami and contributors. Ksign itself includes or derives work from Feather and other open-source projects; their existing notices and acknowledgements are retained in this repository.

Upstream Ksign: https://github.com/nyasami/Ksign

## License

ShrubSign retains the upstream licensing requirements. See `LICENSE`, `LICENSE_ELLEKIT`, bundled acknowledgement files, and the licenses of included dependencies. Fork branding does not remove or replace upstream copyright/license notices.
