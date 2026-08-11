# OpenCSV Demo public-beta metadata

This file is the source draft for App Store Connect. Replace every
`OWNER REQUIRED` field with owner-approved contact data before transmitting
the form to Apple.

## App record

- Platform: iOS
- Name: OpenCSV Demo
- Primary language: English (U.S.)
- Bundle ID: `net.ultravie.signal`
- SKU: `opencsv-signal-demo`
- User access: Full Access

## External testing

- Internal group: OpenCSV Internal
- External group: OpenCSV Public Beta
- Public-link policy: Open to Anyone
- Initial public-link tester limit: 500
- Automatically notify testers: enabled after beta approval

## Beta app description

OpenCSV Demo is preparing a public research beta for sending signet-only Test USD v2 in an
independently built Signal fork. OpenCSV uses client-side proofs while ordinary
Bitcoin signet transactions provide ordering. Test USD has no monetary or
redemption value. This build is not produced, endorsed, or supported by Signal
Messenger, LLC.

The earlier archived binary demonstrates Test USD v1 and must not be offered
or described as v2. A new external build requires the merged v2 Rust revision,
fresh Signal wallet/database/backup namespaces, an exact reviewed v2 issuer
manifest, and new live acceptance receipts before Apple beta review.

## What to test

1. Register a disposable test messaging account.
2. Open Settings, then Wallet, and confirm the cached Test USD and Bitcoin
   signet fee-reserve state appears immediately while synchronization runs.
3. In a one-to-one conversation, open the attachment menu and choose the
   OpenCSV payment action.
4. Send Test USD and confirm the pending chat entry appears before background
   proof work completes.
5. Open the payment receipt and inspect proof, transaction, observer, and
   confirmation evidence.
6. Relaunch after planning or broadcast and report duplicate entries, missing
   balances, stuck operations, crashes, or unclear state.

Use test accounts and test assets only. Third-party builds do not receive
Signal's production push-notification entitlement, so keep the app foregrounded
when immediate delivery matters.

## Beta review notes

This beta uses only Bitcoin signet and valueless test instruments. It has no
mainnet support, arbitrary Bitcoin-send interface, in-app purchases, redemption
promise, or ability to mint assets. The Bitcoin wallet can spend only for an
OpenCSV transfer or protocol-safe fee bump.

The app requires ordinary phone-number registration because it exercises the
messaging transport. Reviewers may register a disposable number. Open the
OpenCSV wallet from Settings > Wallet. The payment action is in the attachment
menu of a one-to-one conversation.

Corresponding source: https://github.com/opencsvnet/Signal-iOS

Public test page: https://opencsv.net/beta/

## Owner-required fields

- Feedback email: `OWNER REQUIRED`
- Review contact first name: `OWNER REQUIRED`
- Review contact last name: `OWNER REQUIRED`
- Review contact email: `OWNER REQUIRED`
- Review contact phone: `OWNER REQUIRED`
