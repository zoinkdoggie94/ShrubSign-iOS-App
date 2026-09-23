# ShrubSign 2.2 — Performance & Stability

This update focuses on making the existing ShrubSign experience calmer, faster, and more reliable instead of adding another large feature set.

## ShrubLibrary catalog
- Catalog remains on-demand: opening ShrubSign itself does not fetch the ShrubLibrary directory.
- Stops automatic re-refresh loops after partial source failures. A failed repository no longer makes the catalog immediately retry the entire directory whenever SwiftUI recreates the screen.
- Uses a 15-minute refresh cooldown for automatic catalog refreshes; manual Refresh always remains available.
- Limits live source requests to three at a time.
- Reuses cached repository data when a source temporarily fails.
- Distinguishes network, timeout, malformed JSON, and incompatible-format errors rather than describing every failure as a blocked repository.
- Throttles search-index refreshes while repositories are streaming in, dramatically reducing repeated full-catalog searches.
- Loads cached repositories in small batches before network refreshes.

## UI and responsiveness
- Home no longer eagerly downloads every custom repository just to render the dashboard.
- Source-list task identity is stable, preventing unnecessary fetches caused by view recreation.
- Removed the full-table crossfade that ran on every repository search keystroke.
- Improved catalog status wording and cached-data indicators.
- Polished Home copy and card backgrounds for a cleaner native grouped appearance.
- Clarified the source-import clipboard action and added a useful empty-clipboard error.

## IPA packaging
- IPA creation now zips a real `Payload` directory instead of a `Payload` symlink.
- Build fails if the IPA archive is corrupt or missing `Payload/ShrubSign.app/Info.plist` or the ShrubSign executable.
- GitHub Actions runs an additional IPA validation step before publishing the beta release.

## Compatibility
- Existing signing engine, certificates, imported apps, custom repositories, signing presets, and app storage remain in place.
- No user data migration is required.
