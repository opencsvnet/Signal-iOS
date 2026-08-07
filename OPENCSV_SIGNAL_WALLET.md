# Signal-native OpenCSV wallet

This fork replaces Signal's payment behavior with an OpenCSV asset wallet and
a Bitcoin fee reserve owned by Rust. Signal transports consignments as normal
encrypted attachments. There is no OpenCSV anchor server and Swift exposes no
general Bitcoin-send, WIF, UTXO-selection, change-address, PSBT, or raw-
transaction API.

## Custody and recovery

- A primary phone stores a random OpenCSV account root and a separate
  `ThisDeviceOnly` binding in Keychain. Rust derives the BIP84 fee wallet,
  OpenCSV owner, and public instrument identities. Signal's binary exports no
  issuer or mint capability.
- Signal Secure Backup carries the account root plus the exact versioned Rust
  checkpoint. The BDK chain graph is rebuildable cache data.
- Transfer, signing, and fee bump remain frozen until a current backup
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

Signal cannot mint or create assets. Privileged test issuance remains in the
non-default, headless `opencsv-issuer` Rust tool; its issuer symbols are absent
from the default Signal XCFramework and header. RBF can only target an
unconfirmed OpenCSV operation and may reduce protected change without altering
the funding input, record, marker, change destination, or output positions.

## Receive and replay safety

Received consignments are verified against the phone-owned chain view. Generic
Esplora is a configurable discovery accelerator, never authoritative spend
state. Rust decode/re-encodes a consignment before assigning its SHA-256
identity. Signal keys verdicts, replay blobs, and presentation to that identity:
byte-distinct delivery retries retain their files but render exactly one
verified payment bubble.

For unconfirmed Test USD, Signal queries both built-in certificate-pinned raw
transaction APIs and persists every success and failure. The default
availability quorum is one: at least one provider must return the fresh exact
transaction bytes under its configured chain pin. A provider outage therefore
does not freeze the wallet, while zero matching providers, stale evidence, pin
mismatch, or changed bytes fail closed. This only unlocks an explicitly
unconfirmed forwardable coin; phone-owned header/BIP158/full-block/Merkle
verification remains mandatory before the UI calls it settled.

The operation journal and pending Signal delivery metadata make every crash
boundary resumable. Cancellation ends at the first broadcast attempt. A
signed-but-unobserved transaction is reported as durable and is never silently
re-armed as a fresh spend.

## Performance and progress

The proof-lineage v4 one-input release receipt measured 6.435 seconds proving,
19.75 ms verification, and 788,047 bytes on the iPhone 16e. Proof work never
belongs on Signal's main actor; the send flow first persists and shows an
immediate pending intent, then proves in the background. Proof,
signing/persistence, relay, observer, and SPV timings are reported separately.
Debug prover builds can take minutes and are not a product-performance receipt.

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

An account database is permanently bound to its Bitcoin network. Advanced
settings reject network changes after account creation instead of repurposing
descriptors, checkpoints, or the sibling `.cbf` cache. Regtest chain resets
and signet/mainnet testing therefore use clean isolated installations; the app
never deletes or silently reuses a cache from another chain.

### Test USD network boundary

The user-facing product reviewed into the current Signal build is **Test USD**.
Wire data continues to use `USD`; Signal derives the Test USD label only from
the exact reviewed, test-only signet identity. It has no
monetary or redemption value, and is admitted only when the Rust account is
bound to Bitcoin signet. Unknown or removed assets remain visible and
read-only with `asset_not_reviewed`. Its asset identity, history, checkpoints,
and BIP84 fee tree must never be promoted or migrated to mainnet.

Production deployment will start with a separately reviewed USD instrument,
issuer manifest, account database, backup namespace, and Bitcoin mainnet fee
tree. Until that explicit production setup exists, the reviewed mainnet issuer
set remains empty and Signal cannot present or transfer a production USD asset.

## 2026-08-07 simulator acceptance journal

- A fresh Bob-to-Carol send proved the one-of-two pinned observer policy in the
  real Signal attachment path. Carol accepted the exact unconfirmed parent and
  rendered `+1 Test USD · available before confirmation · replacement risk`;
  neither a socket write nor an explorer summary was treated as acceptance.
- Carol's first attempt to forward that dollar failed closed as
  `stale_chain_state` before proving. The cause was separate from API
  observation: the old static signet peers were reachable over TCP but no
  longer completed the required two-peer compact-filter session.
- The replacement defaults were resolved from the public signet DNS seed and
  qualified with the OpenCSV readiness probe. `176.9.8.81:38333` paired with
  both `180.189.55.15:38333` and `185.209.178.165:38333`; each pair completed
  independent headers/filter-header synchronization at tip 316659. Nodes that
  merely accepted TCP or omitted compact-filter service bits were rejected.
- A simulator build made with `CODE_SIGNING_ALLOWED=NO` was not a valid
  in-place Signal upgrade: CoreSimulator replaced its app-group containers.
  That failed procedure is forbidden. Simulator and physical-device upgrades
  must use the signed Xcode product, verify the expected application-group
  entitlement, and hash the Signal/OpenCSV databases before and after install.
  The disposable Bob/Carol state is restored from the read-only APFS snapshot
  before acceptance resumes.
- That snapshot exposed a confirmed-protocol-spend rollback independently of
  the observer outage. The corrected Rust bridge rejected Bob operation
  `a05bed708749b0559aba3a7cf27a0cf3` as `stale_chain_state` before proving,
  cancelled its one-member batch, wrote no pending proof, signature, or txid,
  and caused Signal to append one terminal failure after the nonspendable
  intent. Signal now preserves the exact member rejection instead of replacing
  it with the generic `batch_cancelled` label.
