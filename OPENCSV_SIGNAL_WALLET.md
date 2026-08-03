# Signal-native OpenCSV wallet

This fork replaces Signal's payment behavior with an OpenCSV asset wallet and
a Bitcoin fee reserve owned by Rust. Signal transports consignments as normal
encrypted attachments. There is no OpenCSV anchor server and Swift exposes no
general Bitcoin-send, WIF, UTXO-selection, change-address, PSBT, or raw-
transaction API.

## Custody and recovery

- A primary phone stores a random OpenCSV account root and a separate
  `ThisDeviceOnly` binding in Keychain. Rust derives the BIP84 fee wallet,
  OpenCSV owner, and issuer branches.
- Signal Secure Backup carries the account root plus the exact versioned Rust
  checkpoint. The BDK chain graph is rebuildable cache data.
- Mint, transfer, signing, and fee bump remain frozen until a current backup
  succeeds. A restored root without its non-migratable binding opens
  read/export-only; this fork never manufactures a replacement binding.
- Linked devices receive only public BIP84 watch descriptors and the public
  OpenCSV owner identity through Signal's authenticated configuration-sync
  message. Their database is namespaced by owner and Rust rejects every write.

## Write path

The stable Swift boundary sends action intent only:

1. Rust synchronizes the fee wallet and authoritatively verifies selected
   outpoints through headers, BIP158, and verified blocks.
2. Rust reserves the fee input, selects OpenCSV coins, fixes Bitcoin input 0,
   and generates the proof.
3. Signal backs up the exact prepared checkpoint and acknowledges its hash.
4. Rust signs and persists the complete transaction before P2P relay. A
   successful socket write is a submission receipt, not proof of mempool
   acceptance; unless the transaction is independently observable, Rust also
   submits the same persisted bytes through the configured generic relay.
5. Independent observation makes the consignment deliverable through the
   ordinary Signal attachment pipeline.
6. Signal atomically inserts the message and marks the operation/nonce
   delivered. A mempool transaction remains fee-bumpable; confirmation makes
   a delivered operation terminal.

Mint uses the same path and can only issue an asset controlled by this
account's derived issuer. RBF can only target an unconfirmed OpenCSV operation
and may reduce protected change without altering the funding input, record,
marker, change destination, or output positions.

## Receive and replay safety

Received consignments are verified against the phone-owned chain view. Generic
Esplora is a configurable discovery accelerator, never authoritative spend
state. Rust decode/re-encodes a consignment before assigning its SHA-256
identity. Signal keys verdicts, replay blobs, and presentation to that identity:
byte-distinct delivery retries retain their files but render exactly one
verified payment bubble.

The operation journal and pending Signal delivery metadata make every crash
boundary resumable. Cancellation ends at the first broadcast attempt. A
signed-but-unobserved transaction is reported as durable and is never silently
re-armed as a fresh spend.

## Performance and progress

The production first-hop transfer receipt measured 11.253 seconds on the
iPhone 16e. Proof work is serialized by the wallet actor and never belongs on
Signal's main actor; the send flow must keep showing durable progress rather
than treating that interval as a network stall. Debug prover builds can take
minutes and are not a field-performance receipt.

## Legacy MobileCoin state

OpenCSV builds do not start MobileCoin SDK logging, network clients, balance
refresh, reconciliation, payment processing, settings, or attachment actions.
Existing MobileCoin entropy and database rows are not erased. If recovery
material is present, the OpenCSV wallet shows a read-only warning and opens
Signal's authenticated recovery-phrase export flow.

## Rollout boundary

The isolated integration branch is simulator-only until its hosted Rust pin,
both Signal build modes, focused tests, and review gates pass. Installation on
the linked iPhone 16e must be an in-place signed upgrade that preserves its
Signal account and message database. Wiping/relinking the phone, mainnet
broadcast, release, and upstream submission require separate owner approval.
