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
    /// Another send is mid-flight; its coins are not yet marked spent.
    case sendAlreadyInProgress
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
    /// Set for the duration of a send. `sendPayment` releases the actor at
    /// every `await` (context reservation, anchor confirmation), so without
    /// this two concurrent sends would both read the same unspent set and
    /// select the same two coins.
    private var isSending = false
    /// Delivery ids currently being handed to the send pipeline, so a
    /// foreground sweep cannot re-send one that is already in flight.
    private var deliveriesInFlight = Set<String>()

    private var db: any DB { DependenciesBridge.shared.db }
    private var attachmentStore: AttachmentStore { DependenciesBridge.shared.attachmentStore }
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
                    // Resolved, not nil: a consignment whose filename was
                    // stripped is recognised only by its body marker, and
                    // skipping it here would leave it unverified until the
                    // user happened to open the wallet.
                    bodyText: OpenCsvAttachmentDetector.owningMessageBody(of: reference, tx: tx),
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

    /// Sweep a thread's recent messages for consignment attachments that
    /// never got a verdict — e.g. downloaded before the anchor server was
    /// configured, or arrived while the download hook could not verify —
    /// verifying downloaded ones and enqueueing downloads for the rest.
    /// Called when the wallet UI opens on a thread.
    /// Retry every consignment still lacking a verdict, across all
    /// conversations.
    ///
    /// Verification needs the anchor server, which may be unreachable when
    /// a consignment arrives (offline, server down, URL not yet set). Those
    /// attempts deliberately store nothing, so this sweep — run whenever the
    /// app becomes active — is what eventually settles them without the
    /// user having to open any particular screen.
    public func retryAllPendingVerifications() async {
        let threadUniqueIds: [String] = db.read { tx in
            var ids = [String]()
            ThreadFinder().enumerateVisibleThreads(isArchived: false, transaction: tx) { thread in
                ids.append(thread.uniqueId)
            }
            return ids
        }
        for threadUniqueId in threadUniqueIds {
            await retryPendingVerifications(threadUniqueId: threadUniqueId)
        }
    }

    public func retryPendingVerifications(threadUniqueId: String) async {
        struct Sweep {
            var verifiable = [Attachment.IDType]()
            var messagesNeedingDownload = [TSMessage]()
        }
        let sweep: Sweep = db.read { tx in
            var sweep = Sweep()
            var scanned = 0
            try? InteractionFinder(threadUniqueId: threadUniqueId)
                .enumerateInteractionsForConversationView(rowIdFilter: .newest, tx: tx) { interaction in
                    scanned += 1
                    guard
                        let message = interaction as? TSMessage,
                        let messageRowId = message.sqliteRowId
                    else {
                        return scanned < 50
                    }
                    for referenced in attachmentStore.fetchReferencedAttachmentsOwnedByMessage(
                        messageRowId: messageRowId,
                        tx: tx,
                    ) {
                        guard
                            OpenCsvAttachmentDetector.isConsignment(referenced: referenced, tx: tx),
                            store.verdict(attachmentId: referenced.attachment.id, tx: tx) == nil
                        else {
                            continue
                        }
                        if referenced.attachment.asStream() != nil {
                            sweep.verifiable.append(referenced.attachment.id)
                        } else {
                            sweep.messagesNeedingDownload.append(message)
                        }
                    }
                    return scanned < 50
                }
            return sweep
        }
        if !sweep.messagesNeedingDownload.isEmpty {
            let downloadManager = DependenciesBridge.shared.attachmentDownloadManager
            await db.awaitableWrite { tx in
                for message in sweep.messagesNeedingDownload {
                    downloadManager.enqueueDownloadOfAttachmentsForMessage(
                        message,
                        priority: .userInitiated,
                        useThumbnails: false,
                        tx: tx,
                    )
                }
            }
        }
        for attachmentId in sweep.verifiable {
            await verifyDownloadedAttachmentIfNeeded(attachmentId: attachmentId)
        }
    }

    // MARK: - Send pipeline (wallet half)

    /// Prove and anchor a transfer of `amount` to `toOwnerHex`, returning
    /// the consignment blob and the standard body text for its message.
    /// The caller delivers the blob as a normal `opencsv-consignment.bin`
    /// attachment.
    public func sendPayment(
        toOwnerHex: String,
        amount: UInt64,
        threadUniqueId: String,
    ) async throws -> OpenCsvWalletStore.PendingDelivery {
        guard !isSending else {
            throw OpenCsvPaymentsError.sendAlreadyInProgress
        }
        isSending = true
        defer { isSending = false }
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
        // Real chains own the transaction context: reserve one, rebind the
        // (already proved) record to it, and publish. Demo chains return
        // nil and keep the context the prover drew.
        var recordHex = proved.anchorRecordHex
        var ctxHex = proved.ctxHex
        if let reserved = try await provider.reserveContext() {
            recordHex = try wallet.rebind(pendingId: proved.pendingId, ctxHex: reserved)
            ctxHex = reserved
        }
        let anchorRef = try await provider.publishAnchor(recordHex: recordHex, ctxHex: ctxHex)
        let (blob, spends) = try wallet.finalize(pendingId: proved.pendingId, anchorRef: anchorRef)

        // Carry our receiving key so the recipient's wallet can prefill
        // the reply-to address from the chat itself.
        var body = OpenCsvAttachmentDetector.outgoingBody(byteCount: blob.count)
        if let owner = wallet.owners.first {
            body += "\n" + OpenCsvAttachmentDetector.addressAnnouncement(owner: owner)
        }

        // The anchor is confirmed, so these coins are spent on-chain no
        // matter what happens next. Persist the spend and the undelivered
        // consignment *before* anything else — in particular before the
        // snapshot fetch below, which is a network round trip that must not
        // sit between an irreversible on-chain event and its record.
        let currency = inputs.first?.currency
        let deliveryId = UUID().uuidString
        let createdAt = Date()
        let recorded = try await db.awaitableWrite { tx -> OpenCsvWalletStore.PendingDelivery in
            let entry = try self.store.recordOutgoing(blob: blob, spends: spends, tx: tx)
            let recorded = OpenCsvWalletStore.PendingDelivery(
                id: deliveryId,
                threadUniqueId: threadUniqueId,
                body: body,
                replayEntry: entry,
                amount: amount,
                currency: currency,
                assetId: assetId,
                createdAt: createdAt,
            )
            try self.store.addPendingDelivery(recorded, tx: tx)
            return recorded
        }

        // Cache-warm only: credit our own change output. Safe to fail — the
        // replay entry above rebuilds it at next launch.
        if let snapshot = try? await fetchAndCacheSnapshot() {
            _ = try? wallet.verify(
                blob: blob,
                snapshotJson: snapshot,
                requiredConfirmations: Self.requiredConfirmations,
            )
        }
        return recorded
    }

    /// Consignments that are anchored but whose message has not yet reached
    /// the send pipeline, excluding any already in flight or past their
    /// retry limit. The app layer re-enqueues these on foreground.
    public func deliveriesNeedingRetry() -> [OpenCsvWalletStore.PendingDelivery] {
        db.read { self.store.pendingDeliveries(tx: $0) }.filter { delivery in
            if deliveriesInFlight.contains(delivery.id) { return false }
            if delivery.hasExhaustedRetries {
                Logger.warn("OpenCSV delivery \(delivery.id) exhausted retries; leaving it queued")
                return false
            }
            return true
        }
    }

    /// Claim a delivery for one attempt, returning its consignment bytes.
    /// Returns nil if another pass already has it.
    public func beginDelivery(_ delivery: OpenCsvWalletStore.PendingDelivery) async -> Data? {
        guard deliveriesInFlight.insert(delivery.id).inserted else { return nil }
        var attempted = delivery
        attempted.attempts += 1
        return await db.awaitableWrite { tx in
            self.store.updatePendingDelivery(attempted, tx: tx)
            return self.store.blob(forReplayEntry: delivery.replayEntry, tx: tx)
        }
    }

    /// Release a claim after an attempt; the record stays pending unless
    /// the delivery transaction cleared it.
    public func endDelivery(id: String) {
        deliveriesInFlight.remove(id)
    }

    /// Write an outgoing verdict inside the caller's transaction.
    public nonisolated func setOutgoingVerdict(
        _ record: OpenCsvVerdictRecord,
        attachmentId: Attachment.IDType,
        tx: DBWriteTransaction,
    ) {
        OpenCsvWalletStore(keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage)
            .setVerdict(record, blob: nil, attachmentId: attachmentId, tx: tx)
    }

    /// Clear a delivered consignment inside the caller's transaction, so it
    /// commits with the message rather than after it.
    public nonisolated func clearDelivered(id: String, tx: DBWriteTransaction) throws {
        try OpenCsvWalletStore(keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage)
            .removePendingDelivery(id: id, tx: tx)
    }

    /// The verdict to write for a consignment we sent, in the same
    /// transaction that inserts its message.
    public nonisolated func outgoingVerdict(
        for delivery: OpenCsvWalletStore.PendingDelivery,
    ) -> OpenCsvVerdictRecord {
        OpenCsvVerdictRecord(
            sentAmount: delivery.amount,
            currency: delivery.currency,
            assetId: delivery.assetId,
            date: Date(),
        )
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
