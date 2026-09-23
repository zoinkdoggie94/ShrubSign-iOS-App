<p align="center">
  <img src="https://ipa-and-dns-stuff.pages.dev/icons/shrubhub.png" width="160" alt="ShrubSign icon">
</p>

# ShrubSign

**ShrubSign** is ShrubHub's fork of [Ksign](https://github.com/nyasami/Ksign), an iOS app for signing and managing IPA files on supported devices.

## ShrubSign 2 source updates

- New native **Home** tab with the ShrubHub icon, live app/repository/certificate totals, direct file/URL import, repository shortcuts and expiration reminders and certificate search.
- Existing native app search, repository browser, download/import flows, certificates and file manager are available from the dashboard and tabs.
- **Sequential batch signing** from Library selection: visible progress and per-app success or failure; one failed app does not cancel remaining apps.
- GitHub beta release checker in Home and Settings, with an accurate build-SHA comparison when release metadata permits it.
- Built-in ShrubLibrary website discovery link to find more repositories; add compatible repository JSON URLs through the native Add Source flow.
- Optional Discord notifications do not fail the GitHub Actions workflow when `DISCORD_WEBHOOK` is unset.
- Upstream URL-scheme compatibility, licenses and project history retained.

**Build and device testing:** This is the source release. Xcode compilation must be checked with GitHub Actions and signing/import/install behavior on a compatible iOS device. See [SHRUBSIGN_2_CHANGELOG.md](SHRUBSIGN_2_CHANGELOG.md) for exact scope and limitations.

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
