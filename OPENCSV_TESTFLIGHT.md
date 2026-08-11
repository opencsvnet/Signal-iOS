# OpenCSV Demo on TestFlight

This fork can be archived as an internal TestFlight demo under OpenCSV's own
Apple identity. It does not use Signal Messenger, LLC's signing identity,
associated domains, Apple Pay merchant, or privileged push/VoIP entitlements.

## Product identity

- Display name: `OpenCSV Demo`
- Bundle ID: `net.ultravie.signal`
- Notification extension: `net.ultravie.signal.SignalNSE`
- Share extension: `net.ultravie.signal.shareextension`
- Apple team: `2858MX5336`
- Distribution scope: internal TestFlight demonstration

The bundle and app-group identifiers intentionally match the existing OpenCSV
development build. Installing the TestFlight build should therefore remain in
the same demo-app lineage. Back up disposable test state before switching
between development and TestFlight builds.

## Archive

The archive script uses Xcode's automatic signing and verifies the archived
bundle identity, display name, version, and build number before returning.

```sh
OPENCSV_BUILD_NUMBER=1 Scripts/archive-opencsv-testflight.sh
```

Each upload must use a new monotonically increasing build number. The archive
is written to `build/OpenCSV-Demo.xcarchive` by default.

## Upload

After the archive passes local validation:

```sh
Scripts/upload-opencsv-testflight.sh
```

This uses automatic App Store Connect distribution signing for team
`2858MX5336`. An App Store Connect app record for `net.ultravie.signal` must
exist before the first upload.

1. Create or select the App Store Connect app whose bundle ID is
   `net.ultravie.signal`.
2. Open Xcode Organizer, select the archive, choose **Distribute App**, then
   **App Store Connect** and **Upload**.
3. Add only named internal testers until the demo has a release-quality review.
4. Record the source commit, archive version/build, upload receipt, and tester
   group in the OpenCSV issue journal.

## Public beta

External testing is a separate gate from uploading:

1. Create an internal testing group.
2. Create the external `OpenCSV Public Beta` group.
3. Complete the beta description, feedback address, and review-contact fields
   from `OPENCSV_TESTFLIGHT_METADATA.md`.
4. Add the processed build and submit it to TestFlight App Review.
5. After approval, create an open public invitation with an initial limit of
   500 testers.
6. Replace the pending state at `https://opencsv.net/beta/` with the exact
   public invitation URL.

Never publish a guessed invitation URL or describe a processing/reviewing build
as available.

## Known limitation

Signal's production service cannot send Apple Push Notification service events
to a third-party bundle signed under OpenCSV's APNs topic. Do not claim reliable
background message delivery. For the controlled wallet demonstration, keep the
apps foregrounded or reopen them to fetch state. OpenCSV wallet correctness,
signet observation, and transaction proofs do not rely on APNs.

The build remains AGPL-3.0-only and must be accompanied by the corresponding
source. Signal names and artwork remain Signal trademarks; this internal demo
must not be represented as an official Signal release.
