//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// User-facing failures of the OpenCSV payment flows.
public enum OpenCsvPaymentsError: Error {
    /// No anchor server URL is configured (required to send).
    case anchorServerNotConfigured
    /// The wallet holds fewer than the two spendable coins a transfer needs.
    case needTwoCoins
    /// Unspent total is below the requested amount.
    case insufficientFunds(available: UInt64)
}

/// The OpenCSV payments service: owns the in-memory Rust wallet and runs the
/// receive pipeline (consignment attachment → verify → verdict → re-render)
/// and the wallet half of the send pipeline (prove → publish anchor →
/// finalize → persist). Transport stays with the caller: the send UI
/// enqueues the returned blob through the normal message pipeline.
///
/// An actor: FFI wallet handles are not thread-safe, and proving takes
/// ~0.5–1 s on phone hardware, so all wallet work is serialized off the
/// main thread here.
public actor OpenCsvPayments {
    public static let shared = OpenCsvPayments()

    /// Confirmation depth required of a consignment's anchor (paper §4.7).
    public static let requiredConfirmations: UInt64 = 6

    private var wallet: OpenCsvWallet?

    private var db: any DB { DependenciesBridge.shared.db }
    private var attachmentStore: AttachmentStore { DependenciesBridge.shared.attachmentStore }
    private var interactionStore: any InteractionStore { DependenciesBridge.shared.interactionStore }
    private var store: OpenCsvWalletStore {
        OpenCsvWalletStore(keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage)
    }

    /// What the settings/send UI needs to render.
    public struct WalletSummary {
        /// The wallet's receiving key (share with senders; e.g. mint target).
        public let owner: String
        public let balances: [OpenCsvCredit]
        public let unspentCoins: [OpenCsvCoin]
        public let anchorServerUrl: URL?
    }

    // MARK: - Receive pipeline

    /// Called (fire-and-forget) when an attachment finishes downloading.
    /// Verifies it iff it is an OpenCSV consignment without a stored
    /// verdict, then persists the verdict and re-renders owning messages.
    ///
    /// Infrastructure failures (no snapshot reachable, wallet unavailable)
    /// store nothing, so a later retry can still verify; only a definitive
    /// prover accept/reject is persisted.
    public func verifyDownloadedAttachmentIfNeeded(attachmentId: Attachment.IDType) async {
        struct Candidate {
            let stream: AttachmentStream
        }
        let candidate: Candidate? = db.read { tx in
            guard store.verdict(attachmentId: attachmentId, tx: tx) == nil else {
                return nil
            }
            guard let stream = attachmentStore.fetch(id: attachmentId, tx: tx)?.asStream() else {
                return nil
            }
            var isConsignment = false
            attachmentStore.enumerateAllReferences(toAttachmentId: attachmentId, tx: tx) { reference, _ in
                if OpenCsvAttachmentDetector.isConsignment(
                    sourceFilename: reference.sourceFilename,
                    mimeType: stream.mimeType,
                    bodyText: nil,
                ) {
                    isConsignment = true
                }
            }
            return isConsignment ? Candidate(stream: stream) : nil
        }
        guard let candidate else { return }

        let blob: Data
        do {
            blob = try candidate.stream.decryptedRawData()
        } catch {
            Logger.warn("could not read consignment attachment: \(error)")
            return
        }

        do {
            let verdict = try await verifyBlob(blob)
            let record = OpenCsvVerdictRecord(verdict: verdict, date: Date())
            await db.awaitableWrite { tx in
                self.store.setVerdict(record, blob: blob, attachmentId: attachmentId, tx: tx)
                self.touchOwners(attachmentId: attachmentId, tx: tx)
            }
            Logger.info("consignment \(attachmentId): \(record.status)")
        } catch {
            Logger.warn("consignment \(attachmentId) not verifiable yet: \(error)")
        }
    }

    /// Verify a consignment blob against the current anchor snapshot,
    /// crediting any of our coins it contains.
    public func verifyBlob(_ blob: Data) async throws -> OpenCsvVerdict {
        let wallet = try await ensureWallet()
        let snapshot = try await fetchAndCacheSnapshot()
        return try wallet.verify(
            blob: blob,
            snapshotJson: snapshot,
            requiredConfirmations: Self.requiredConfirmations,
        )
    }

    // MARK: - Send pipeline (wallet half)

    /// Prove and anchor a transfer of `amount` to `toOwnerHex`, returning
    /// the consignment blob and the standard body text for its message.
    /// The caller delivers the blob as a normal `opencsv-consignment.bin`
    /// attachment.
    public func sendPayment(toOwnerHex: String, amount: UInt64) async throws -> (blob: Data, body: String) {
        let wallet = try await ensureWallet()

        let unspent = try wallet.coins().filter(\.unspent)
        guard let assetId = unspent.first?.assetId else {
            throw OpenCsvPaymentsError.insufficientFunds(available: 0)
        }
        // The transfer circuit is fixed at 2 inputs: pick the two largest
        // coins of the asset (zero-value padding coins count).
        let candidates = unspent.filter { $0.assetId == assetId }.sorted { $0.value > $1.value }
        guard candidates.count >= 2 else {
            throw OpenCsvPaymentsError.needTwoCoins
        }
        let inputs = Array(candidates.prefix(2))
        let total = inputs.reduce(0) { $0 + $1.value }
        guard total >= amount else {
            throw OpenCsvPaymentsError.insufficientFunds(available: total)
        }

        guard let anchorUrl = db.read(block: { store.anchorServerUrl(tx: $0) }) else {
            throw OpenCsvPaymentsError.anchorServerNotConfigured
        }
        let provider = RemoteOpenCsvAnchorProvider(baseURL: anchorUrl)

        let amounts = total == amount ? [amount] : [amount, total - amount]
        let proved = try wallet.proveTransfer(
            coinIds: inputs.map(\.id),
            toOwnerHex: toOwnerHex,
            amounts: amounts,
        )
        let anchorRef = try await provider.publishAnchor(recordHex: proved.anchorRecordHex)
        let (blob, spends) = try wallet.finalize(pendingId: proved.pendingId, anchorRef: anchorRef)

        // Ingest our own consignment to credit the change output, against
        // the post-anchor snapshot (kept for offline startup replay).
        if let snapshot = try? await fetchAndCacheSnapshot() {
            _ = try? wallet.verify(
                blob: blob,
                snapshotJson: snapshot,
                requiredConfirmations: Self.requiredConfirmations,
            )
        }
        await db.awaitableWrite { tx in
            self.store.recordOutgoing(blob: blob, spends: spends, tx: tx)
        }
        // Carry our receiving key so the recipient's wallet can prefill
        // the reply-to address from the chat itself.
        var body = OpenCsvAttachmentDetector.outgoingBody(byteCount: blob.count)
        if let owner = wallet.owners.first {
            body += "\n" + OpenCsvAttachmentDetector.addressAnnouncement(owner: owner)
        }
        return (blob, body)
    }

    // MARK: - Settings / status

    public func walletSummary() async throws -> WalletSummary {
        let wallet = try await ensureWallet()
        let coins = try wallet.coins()
        return WalletSummary(
            owner: wallet.owners.first ?? "",
            balances: try wallet.balance(),
            unspentCoins: coins.filter(\.unspent),
            anchorServerUrl: db.read { store.anchorServerUrl(tx: $0) },
        )
    }

    public func setAnchorServerUrl(_ urlString: String?) async {
        await db.awaitableWrite { tx in
            self.store.setAnchorServerUrl(urlString, tx: tx)
        }
    }

    /// A stored verdict, for the conversation cell (main-thread render path).
    public nonisolated func verdict(attachmentId: Attachment.IDType, tx: DBReadTransaction) -> OpenCsvVerdictRecord? {
        OpenCsvWalletStore(keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage)
            .verdict(attachmentId: attachmentId, tx: tx)
    }

    // MARK: - Wallet lifecycle

    /// Open (or create) the wallet and rebuild coin state by replaying
    /// stored consignment blobs against the cached snapshot.
    private func ensureWallet() async throws -> OpenCsvWallet {
        if let wallet {
            return wallet
        }
        let secrets: String
        if let stored = try store.walletSecrets() {
            secrets = stored
        } else {
            secrets = try OpenCsvWallet.createSecrets()
            try store.setWalletSecrets(secrets)
        }
        let wallet = try OpenCsvWallet(secretsJson: secrets)

        let (replay, spent, cachedSnapshot) = db.read { tx in
            (
                store.replayBlobs(tx: tx),
                store.spentCoinIds(tx: tx),
                store.lastSnapshotJson(tx: tx),
            )
        }
        if !replay.isEmpty, let snapshot = cachedSnapshot {
            for (entry, blob) in replay {
                do {
                    let verdict = try wallet.verify(
                        blob: blob,
                        snapshotJson: snapshot,
                        requiredConfirmations: Self.requiredConfirmations,
                    )
                    if !verdict.isVerified {
                        Logger.warn("replay of \(entry) rejected: \(verdict.reason ?? "?")")
                    }
                } catch {
                    Logger.warn("replay of \(entry) failed: \(error)")
                }
            }
            try? wallet.markSpent(coinIds: spent)
        }
        self.wallet = wallet
        return wallet
    }

    private func fetchAndCacheSnapshot() async throws -> String {
        let anchorUrl = db.read { store.anchorServerUrl(tx: $0) }
        guard let anchorUrl else {
            // Demo mode: no server configured; verification runs against
            // the cached (or empty) snapshot.
            if let cached = db.read(block: { store.lastSnapshotJson(tx: $0) }) {
                return cached
            }
            return try await DemoOpenCsvAnchorProvider().fetchSnapshotJson()
        }
        let snapshot = try await RemoteOpenCsvAnchorProvider(baseURL: anchorUrl).fetchSnapshotJson()
        await db.awaitableWrite { tx in
            self.store.setLastSnapshotJson(snapshot, tx: tx)
        }
        return snapshot
    }

    private nonisolated func touchOwners(attachmentId: Attachment.IDType, tx: DBWriteTransaction) {
        let interactionStore = DependenciesBridge.shared.interactionStore
        let db = DependenciesBridge.shared.db
        DependenciesBridge.shared.attachmentStore.enumerateAllReferences(
            toAttachmentId: attachmentId,
            tx: tx,
        ) { reference, _ in
            guard case .message(let messageSource) = reference.owner else { return }
            guard let interaction = interactionStore.fetchInteraction(rowId: messageSource.messageRowId, tx: tx) else {
                return
            }
            db.touch(interaction: interaction, shouldReindex: false, tx: tx)
        }
    }
}
