
## ShrubSign 3.1 — Signing is easy with ShrubSign

- **Quick Sign Pro:** reusable signing presets with optional per-app rules and Quick Sign & Install.
- **IPA Inspector:** native bundle metadata, executable structure, frameworks, extensions, compatibility notices, and report sharing.
- **Tweak Studio:** save and reuse selections of actual locally stored tweaks.
- **Signing Center:** real signing operation outcomes and safe retry navigation.
- **ShrubLibrary Ultra:** saved apps, available-version comparisons across loaded repositories, and saved-app update notices after manual refresh.
- **Certificate Lab:** readable provisioning compatibility and expiration checks.
- **Signing Queue:** safe stop-after-current control for bulk signing.
- **ShrubCerts:** certificate-store shortcut in Settings and Home (`https://shrubcerts.pages.dev`).

Note: ShrubSign does not guarantee signing or install success for every IPA/certificate. The app remains based on the upstream open-source project and retains applicable license notices.

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

# ShrubSign 3.1 acceptance checklist

Build using GitHub Actions on macOS/Xcode. Source parsing on Linux does not guarantee SwiftUI type checking or successful device operation.

1. Verify app starts in light/dark appearance, portrait/landscape and iPad split view.
2. Settings → ShrubCerts opens https://shrubcerts.pages.dev and does not disclose local certificates.
3. Import a known-good IPA, inspect it, verify actual executable, framework and extension counts.
4. Save a signing preset, configure a per-app rule and sign using Quick Sign. Verify actual signed IPA is created.
5. With two imported IPAs, batch sign and use Stop queue after current IPA; verify the first completes and the next does not start.
6. Open Signing Center: completed and failed operations show status and error reason. Reopen app and confirm history persists.
7. Save multiple tweak files, create a Tweak Studio profile, deselect and apply it; verify same saved files are restored.
8. Refresh ShrubLibrary, save a listing, compare same app across sources, close/reopen app and check favorites persist.
9. Refresh later after source version changes; verify What's New notices appear only for tracked saved apps.
10. Verify the existing installation methods with a known-good certificate and supported app. Quick Sign & Install must target the signed app, not an unrelated latest entry.
11. Verify older releases remain published; IPA has real Payload folder, Info.plist and executable.
12. Test large IPAs with adequate free space. Inspect signing failures, compare timings and ensure no expired certificate is silently selected.

Do not publish a stable release until all applicable checks pass on actual hardware.

