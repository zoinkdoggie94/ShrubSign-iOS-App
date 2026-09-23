# ShrubSign 2.1 · Release notes and verification checklist

## Implemented in source

1. Native on-demand ShrubLibrary catalog: `repos.txt`, separate repositories, background decoding, limited concurrency, progressive result visibility, repository error reporting, on-device caches and manual refresh. Existing custom sources also appear in unified search. Duplicate listings remain separate.
2. Signing presets: save/apply/rename/delete/default and certificate reference validation. A batch preset applies its signing options to each selected app without discarding each app's custom identity.
3. Certificate screen: search, expiration/status filters, sorting, preferred certificate persistence, and explicit non-live revocation wording.
4. IPA details: signed/imported status, source URI when available, extracted app-size information. Repository app details show available screenshot formats.
5. Download behavior: progress including unknown-size transfers, cancel, error records and retry, HTTP/non-ZIP response validation, collision-safe filenames, and fix for importing a local completed IPA rather than its remote URL.

## Test on device after the GitHub Actions build

- Launch Home, enter ShrubLibrary: confirm the app remains responsive while sources load, and that independent copies of an app show their own repository names.
- Search an app, open its details, download an IPA from a source you trust, and confirm the existing import and sign flows. Inspect the Downloads tab for progress, cancel, and a useful error if a URL fails.
- Add a custom source. Verify it is browsable and searchable without duplicate catalog sources. Relaunch the app and check that cached catalog entries appear.
- Open an imported app's signing screen, save a preset, apply it, sign an app, and test a batch with that preset. Try deleting the certificate referenced by a preset and ensure a warning appears.
- Check certificate filtering/sorting and the imported/signed app detail pages on iPad portrait and landscape. Check both light and dark appearances.

## Known limitations

- This source archive has undergone Swift syntax and packaging checks, **not** a full Xcode compile or device test in this environment.
- The catalog accepts repositories parsed by the existing AltSourceKit parser; incompatible formats, dead URLs, unsupported PAL-only sources, malformed entries, and blocked hosts are reported per repository rather than invented as catalog entries.
- Search retains the first 1,200 matched entries for display to bound memory use. Narrow a search to find entries beyond that window. Data is cached on-device, and users can manually refresh.
- The metadata/UI does not assess the security of third-party IPAs. Signing a downloaded IPA requires an appropriate user-provided identity.
- Live Apple revocation verification is not implied by a certificate's expiration date or a saved revocation flag.

Upstream licenses and attribution remain in this project. Keep the working 2.0 IPA until your 2.1 build has been installed and verified on your device.
