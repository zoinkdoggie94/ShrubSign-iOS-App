<p align="center">
  <img src="https://ipa-and-dns-stuff.pages.dev/icons/shrubhub.png" width="160" alt="ShrubSign icon">
</p>

# ShrubSign

**ShrubSign** is ShrubHub's fork of [Ksign](https://github.com/nyasami/Ksign), an iOS app for signing and managing IPA files on supported devices.

## What changed in the initial ShrubSign fork

- ShrubSign app name, bundle identifier, project/target names and release package names
- ShrubHub app icon and branding
- `shrubsign://` URL scheme, while retaining `ksign://` as a compatibility alias
- ShrubSign GitHub/Discord/ShrubLibrary links
- ShrubSign AltStore-compatible `repo.json`
- ShrubSign beta build output (`ShrubSign.ipa`)
- ShrubSign source defaults and log export names

The internal compatibility identifiers that would risk breaking existing behavior are intentionally preserved where appropriate.

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
