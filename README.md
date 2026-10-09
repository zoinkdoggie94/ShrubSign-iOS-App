<p align="center">
  <img src="https://ipa-and-dns-stuff.pages.dev/icons/shrubhub.png" width="160" alt="ShrubSign icon">
</p>

# ShrubSign

**Signing is easy with ShrubSign.**

ShrubSign is ShrubHub's iOS IPA signing and app-management project, based on [Ksign](https://github.com/nyasami/Ksign) and the upstream Feather work it builds upon.

## ShrubSign 3.0

This release focuses on making the app feel dependable rather than simply adding more features:

- **Signing reliability:** duplicate tweak-injection passes were removed and signing errors are now surfaced before a broken result is saved to the library.
- **Tweak & dylib injection:** dylib/framework injection validates the Mach-O injection result, reports useful failures, avoids duplicate injected names, and cleans temporary extraction data.
- **Repository stability:** opening one saved repository now fetches only that repository instead of refreshing every source, and the UIKit app table has bounds checks to avoid stale-index crashes while data changes.
- **ShrubLibrary persistence:** previously cached ShrubLibrary repositories are restored incrementally without re-downloading every source on every launch; network refresh remains user-controlled.
- **Installation reliability:** install progress no longer polls every millisecond, missing bundle identifiers and malformed install links are handled as errors instead of force-unwrapped crashes, and server-start failures are surfaced in the install UI.
- **Certificates:** certificate details now show profile UUID, creation and expiration dates, team ID, application identifier, TTL, profile type, provisioned-device count, and accurate local-status wording.
- **UI polish:** the Home dashboard and catalog loading states are cleaner, long text is handled more safely, and the app uses the ShrubSign motto consistently.
- **Release history:** GitHub Actions publishes a new uniquely tagged release for each successful build instead of deleting the previous release, so older IPA assets remain available.

## Building

Clone recursively, then build with Xcode or run:

```sh
make
```

The makefile creates `packages/ShrubSign.ipa` and validates the IPA archive structure before release.

## Upstream & credits

ShrubSign is based on **Ksign** by Nyasami/Nagata Asami and contributors. Ksign itself includes or derives work from Feather and other open-source projects; their notices and acknowledgements are retained.

Upstream Ksign: https://github.com/nyasami/Ksign

## License

ShrubSign retains the upstream licensing requirements. See `LICENSE`, `LICENSE_ELLEKIT`, bundled acknowledgements, and dependency licenses. Fork branding does not remove or replace upstream copyright or license notices.
