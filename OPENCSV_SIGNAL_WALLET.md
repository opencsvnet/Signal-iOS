# Signal-native OpenCSV wallet

## Test USD v2 reset (2026-08-11)

Bitcoin Signet is unchanged, but this branch deliberately starts a fresh
OpenCSV application deployment. Account config generation 2 and deployment id
`opencsv-test-usd-v2` are passed to Rust; Signal uses
`OpenCsvPayments.testUsd.v2` KeyValueStore/Keychain state and the
`opencsv-test-usd-v2/account-v2.sqlite` database. V1 wallet roots, addresses,
balances, checkpoints, backups, and reviewed issuer entries are not migrated.
Rust rejects old state with `testnet_reset_required`, which the wallet renders
as a fresh-wallet instruction rather than crashing.

The old issuer allowlist is removed. The v2 registry pins exact backed-up
headless manifest asset
`8a88b56e42450f5761b521063df3fa16806add5c434584441d3b626556115d62`;
Signal holds no issuer secret and still cannot mint. Existing Bob/Carol
transactions and media are archived v1 evidence; a new v2 live run is required
before TestFlight or release claims.

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
transaction APIs and persists every success and failure. Every raw observer
configured as `require` must return the fresh exact transaction bytes under its
configured chain pin; the signet defaults therefore require both providers.
An outage, stale evidence, pin mismatch, or changed bytes fails closed for
zero-confirmation forwarding. This only unlocks an explicitly unconfirmed
forwardable coin; phone-owned header/BIP158/full-block/Merkle verification
remains mandatory before the UI calls it settled.

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

The TestFlight archive gate derives the exact 40-character Git commit from
`HEAD`, rejects tracked, staged, or untracked source drift outside generated
Pods, embeds that commit as `OpenCSVSourceCommit` in the signed application
plist, and reads it back from the completed archive. A build number or local
archive filename alone is not accepted as a source receipt.

An account database is permanently bound to its Bitcoin network. Advanced
settings reject network changes after account creation instead of repurposing
descriptors, checkpoints, or the sibling `.cbf` cache. Regtest chain resets
and signet/mainnet testing therefore use clean isolated installations; the app
never deletes or silently reuses a cache from another chain.

### Archived v1 Test USD network boundary

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

### 2026-08-11 archived-attachment admission decision

Fresh v2 installations can still display ordinary Signal messages carrying
archived v1 consignment attachments. Before this change, Signal started chain
discovery before deciding whether the attachment's asset belonged to the exact
v2 reviewed-issuer registry. A missing historical signet anchor therefore
looked like retryable network lag and could leave the message at “verifying”
forever.

Rust now returns the canonical recipient asset identities and the exact
reviewed-issuer admission result from consignment inspection. Signal evaluates
that deterministic result before any explorer or compact-filter work. An
unknown or removed instrument is retained in message history and rendered as
`asset_not_reviewed`; it is never credited, made spendable, or relabeled as
Test USD v2. Contradictory inspection fields fail closed with the same result.
Only admitted v2 consignments proceed to retryable observer and chain checks.

Two broader fixes were considered and rejected. Treating every missing anchor
as terminal would misclassify genuine observer or chain lag. Deleting old
attachment state or rewriting its timestamps would hide history without
establishing protocol evidence. The focused Signal suite covers reviewed,
archived, and contradictory inspection results; Rust separately covers a
mixed reviewed/unreviewed consignment against the exact registry predicate.

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
- Carol then authored one explicit two-recipient batch: 5 Test USD to Bob and
  5 Test USD to Note to Self. Operations
  `afcaa691e4a0adb3cfd24a6f986400d0` and
  `bc1850940e9e8f2c3af747aa60852725` share Bitcoin transaction
  `771aefc62e38dae80b4fdeec5ebb183c5c4c53c7902b559991aa55679103c4c3`.
  Three ordinary Bitcoin peers accepted complete writes; mempool.space and
  Blockstream returned the same raw bytes in 271 ms and 354 ms. Forced exits
  after proof generation and after broadcast resumed the same batch,
  operation ids, and txid without another spend or duplicate attachment.
- The first receive attempt uncovered two independent verifier integration
  errors. Rust was authenticating the full batching-v2 envelope but trying to
  prove that envelope as a legacy single-transfer statement, producing
  `InvalidProof`; after exact-member projection, Signal still ran ownership
  preflight through its retired legacy wallet and produced `NoOwnedOutput` for
  the correct account-wallet recipient. The accepted repair projects only the
  authenticated batch member in Rust, retains the full batch envelope in the
  exported verified snapshot, and uses the same Rust account identity for
  preflight and crediting. Stored verdict versions allow each known-bad verdict
  to be retried once without weakening current definitive rejections.
- At signet block 316694 the corrected in-place builds rendered Bob's exact
  batch member as `+5 Test USD` fully verified and Carol's self member as
  verified. Bob showed 44 Test USD and Carol 131 Test USD. A second app relaunch
  left their account databases at 7 and 11 consignments respectively, proving
  that attachment replay did not create another credit. The transaction was
  settled before this verifier correction landed, so this receipt proves the
  real shared transaction, crash recovery, and settled recipient verification;
  the earlier 1 Test USD parent/child run remains the zero-confirmation receipt.

## 2026-08-12 cached-state send and chain-verification retry boundary

The fresh Test USD v2 Carol-to-Bob attempt proved that cached wallet rendering
and durable chat intent work, but also exposed a sequencing defect. Signal
made the send form usable while the compact-filter scan continued in parallel;
background proving could therefore race that mandatory scan. Operation
`dbfeed5be1f83f94e662947bdb07137d` and solo batch
`15316e14d8aa5746adc906f220947a84` survived an app termination at
`fee_reserved`, but the previous Rust policy converted temporary chain-view
unavailability into terminal `stale_chain_state`. It wrote no proof, signed
transaction, txid, broadcast, or asset spend. The failed chat intent remains
visible and is excluded from acceptance media.

Signal now requires a successful phone-owned compact-filter sync immediately
before starting a queued solo or frozen multi-recipient proof. Cached balances
still render without blocking and the pending chat entry remains durable while
the scan catches up. If sync fails, the operation is left queued for the next
foreground or BGProcessing pass. Rust independently enforces the same
distinction: transient peer/scan outages preserve the exact unsigned operation
and fee reservation, while a verified spend, rollback, byte mismatch, proof
failure, or policy violation remains terminal and can never reach signing.

The same simulator audit found archived pre-v2 attachments repeatedly failing
strict canonical decoding while the UI kept calling them “verifying.” Signal
now preserves Rust's stable `invalid_consignment` reason across the FFI and
stores one terminal, nonspendable “needs attention” verdict for that immutable
payload. Peer, observer, and chain-view failures remain retryable. No legacy
blob is deleted or reinterpreted, and current Test USD v2 credit is unchanged.
