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
    /// The wallet holds more than one asset and none was chosen.
    case assetNotSpecified(available: [String])
    /// The recipient key is not 32 bytes of hex.
    case malformedRecipient
    /// The attachment is empty or too large to be a consignment.
    case consignmentSizeRejected(bytes: Int)
    /// The proved transaction could not be made crash-recoverable, so it
    /// was not anchored.
    case couldNotPersistPendingSend(underlying: String)
    /// Configured indexers reported different chain tips. At least one is
    /// wrong or lying and there is no way to tell which, so nothing they
    /// say can be trusted for this decision.
    case indexersDisagree(tips: [UInt64])
    /// A verified consignment's anchor was missing from the very snapshot
    /// it was verified against — a programming error surfaced loudly, not
    /// a chain fact.
    case snapshotMissingAnchor(height: UInt64, position: UInt32)
    /// SPV could not settle the claimed anchor either way (our tip lags,
    /// confirmations still accruing, peers unreachable). Nothing is
    /// stored; the verification stays retryable.
    case spvUnsettled(status: String, reason: String?)
    /// The scan index has not caught up to the payment's anchor yet
    /// (AnchorNotFound / InsufficientConfirmations). Nothing is stored;
    /// the sweep retries once the chain view advances.
    case chainViewLagging(reason: String)
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

    /// Largest consignment this wallet will hand to the verifier.
    ///
    /// Verification is serialized on this actor, so an attacker who can
    /// send attachments could otherwise stall every payment in the app by
    /// attaching a huge "consignment". Real ones are ~47–57 KB; a megabyte
    /// is generous and still cheap to reject.
    public static let maxConsignmentBytes = 1024 * 1024

    private var wallet: OpenCsvWallet?
    /// Set for the duration of a send. `sendPayment` releases the actor at
    /// every `await` (context reservation, anchor confirmation), so without
    /// this two concurrent sends would both read the same unspent set and
    /// select the same two coins.
    private var isSending = false
    /// Delivery ids currently being handed to the send pipeline, so a
    /// foreground sweep cannot re-send one that is already in flight.
    private var deliveriesInFlight = Set<String>()
    /// Whether a self-scan sync has succeeded this process. `scanVerify`
    /// consults the index the last successful sync registered, so until
    /// this is true a scan decision would only throw "no scan registered".
    private var scanSyncedThisLaunch = false
    /// The last successful sync's counters, for the explorer sheet's
    /// "this phone's chain view" section. In-memory only.
    private var lastScanSyncSummary: OpenCsvChainView.ScanSyncResult?
    /// The last withheld (retryable) verification failure per attachment,
    /// for the explorer sheet. Deliberately never persisted — a withheld
    /// verdict stores nothing by design; this is display-only honesty
    /// about the most recent attempt.
    private var lastWithheldReason = [Attachment.IDType: String]()
    /// Guards against overlapping syncs: the sync writes the on-disk
    /// index, and app-activation can fire while a lazy sync is running.
    private var scanSyncInFlight = false

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
        /// Bitcoin P2P peers powering self-scan and SPV point-verify.
        public let spvPeers: [String]
        /// Bitcoin network for the chain views ("signet" default).
        public let network: String
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
            let verdict = try await verifyBlobWithConfiguredChainView(blob)
            let record = OpenCsvVerdictRecord(verdict: verdict, date: Date())
            await db.awaitableWrite { tx in
                self.store.setVerdict(record, blob: blob, attachmentId: attachmentId, tx: tx)
                self.touchOwners(attachmentId: attachmentId, tx: tx)
            }
            lastWithheldReason[attachmentId] = nil
            Logger.info(
                "consignment \(attachmentId): \(record.status)"
                + (record.reason.map { " (\($0))" } ?? "")
                + " via \(record.chainView ?? "?")",
            )
        } catch {
            lastWithheldReason[attachmentId] = "\(error)"
            Logger.warn("consignment \(attachmentId) not verifiable yet: \(error)")
        }
    }

    /// Decide whether a consignment should be believed, using the
    /// strongest chain view configured, then credit it.
    ///
    /// The two halves are deliberately separate. Exclusion — has any of
    /// these nullifiers appeared earlier? — is decided first, by the
    /// strongest configured view (see `chainViewPlan`); crediting is local
    /// bookkeeping and stays on one path. A verified verdict then gets its
    /// claimed anchor SPV-checked against the chain itself where peers are
    /// configured, so even the crediting snapshot's server is not simply
    /// believed.
    public func verifyBlobWithConfiguredChainView(_ blob: Data) async throws -> OpenCsvVerdict {
        guard !blob.isEmpty, blob.count <= Self.maxConsignmentBytes else {
            throw OpenCsvPaymentsError.consignmentSizeRejected(bytes: blob.count)
        }
        let wallet = try await ensureWallet()
        let (peers, indexers) = db.read {
            (self.store.spvPeers(tx: $0), self.store.indexerUrls(tx: $0))
        }

        let plan = Self.chainViewPlan(peerCount: peers.count, indexerCount: indexers.count)
        switch plan {
        case .selfScan:
            // The phone's own filter-synced occurrence index; no server is
            // asked and none is believed. An unsynced index throws — a
            // weaker view must never be substituted silently.
            if !scanSyncedThisLaunch {
                await scanSyncIfNeeded()
            }
            var scanned = try OpenCsvChainView.scanVerify(wallet: wallet, consignment: blob)
            if !scanned.isVerified, Self.isChainLagReason(scanned.reason) {
                // A payment message routinely beats the chain view by
                // seconds: the anchor exists, the index just hasn't seen
                // it. One fresh (resumed, cheap) sync and retry before
                // any verdict is allowed to exist.
                await scanSyncIfNeeded()
                scanned = try OpenCsvChainView.scanVerify(wallet: wallet, consignment: blob)
            }
            guard scanned.isVerified else {
                if Self.isChainLagReason(scanned.reason) {
                    // Still behind after a resync: infrastructure, never a
                    // final verdict — the sweep re-runs when the chain
                    // catches up. A lagging tip must not reject a payment.
                    throw OpenCsvPaymentsError.chainViewLagging(reason: scanned.reason ?? "?")
                }
                var verdict = OpenCsvVerdict(
                    status: "rejected",
                    reason: scanned.reason ?? "self-scan rejected",
                    credits: nil,
                    coins: nil,
                    anchor: nil,
                )
                verdict.chainView = plan.rawValue
                return verdict
            }

        case .crossCheck:
            let crossChecked = try OpenCsvChainView.crossCheck(
                wallet: wallet,
                backends: indexers.map { .http(url: $0) },
                consignment: blob,
                requiredConfirmations: Self.requiredConfirmations,
            )
            if crossChecked.isTipDisagreement {
                // One of these indexers is wrong or lying and we cannot
                // tell which, so no answer here is trustworthy.
                throw OpenCsvPaymentsError.indexersDisagree(tips: crossChecked.tips ?? [])
            }
            guard crossChecked.isVerified else {
                var verdict = OpenCsvVerdict(
                    status: "rejected",
                    reason: crossChecked.reason ?? crossChecked.error ?? "cross-check rejected",
                    credits: nil,
                    coins: nil,
                    anchor: nil,
                )
                verdict.chainView = plan.rawValue
                return verdict
            }

        case .singleSnapshot:
            if indexers.count == 1 {
                Logger.warn(
                    "OpenCSV exclusion rests on a single indexer: a dishonest one can hide a "
                    + "double-spend. Configure SPV peers for self-scan, or several independent "
                    + "indexers.",
                )
            }
        }

        // Believed (or undecidable beyond the single snapshot): credit
        // through the wallet's single crediting path, then hold the
        // snapshot's claimed anchor up against the chain itself.
        var (verdict, snapshotJson) = try await verifyBlobReturningSnapshot(blob)
        verdict.chainView = plan.rawValue
        return try await spvPointVerifyIfConfigured(verdict, snapshotJson: snapshotJson)
    }

    /// Which exclusion decision the current configuration can support,
    /// strongest first. Pure so the ordering is testable.
    enum ChainViewPlan: String {
        case selfScan = "self-scan"
        case crossCheck = "cross-check"
        case singleSnapshot = "single-snapshot"
    }

    static func chainViewPlan(peerCount: Int, indexerCount: Int) -> ChainViewPlan {
        if peerCount > 0 {
            return .selfScan
        }
        if indexerCount >= 2 {
            return .crossCheck
        }
        return .singleSnapshot
    }

    /// Scan rejections that mean "the chain view hasn't caught up", not
    /// "this payment is bad": never final, always retryable. Pure so the
    /// classification is testable.
    static func isChainLagReason(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason.contains("AnchorNotFound") || reason.contains("InsufficientConfirmations")
    }

    /// Verify a consignment blob against the current anchor snapshot,
    /// crediting any of our coins it contains.
    public func verifyBlob(_ blob: Data) async throws -> OpenCsvVerdict {
        try await verifyBlobReturningSnapshot(blob).verdict
    }

    /// As `verifyBlob`, also returning the snapshot JSON the verdict was
    /// produced against — the only place a claimed anchor's txid and
    /// record bytes exist on this side of the FFI, so SPV needs it.
    private func verifyBlobReturningSnapshot(
        _ blob: Data,
    ) async throws -> (verdict: OpenCsvVerdict, snapshotJson: String) {
        guard !blob.isEmpty, blob.count <= Self.maxConsignmentBytes else {
            throw OpenCsvPaymentsError.consignmentSizeRejected(bytes: blob.count)
        }
        let wallet = try await ensureWallet()
        let snapshot = try await fetchAndCacheSnapshot()
        let verdict = try wallet.verify(
            blob: blob,
            snapshotJson: snapshot,
            requiredConfirmations: Self.requiredConfirmations,
        )
        return (verdict, snapshot)
    }

    /// Check a just-credited consignment's claimed anchor against the
    /// chain itself (PoW headers → one block → merkle branch) where SPV
    /// peers are configured.
    ///
    /// This runs after crediting because the claim's location is only
    /// learnable from the crediting verify. The window is bounded: a
    /// definitive negative rewrites the verdict to rejected, rejects store
    /// no replay blob, so the phantom in-memory credit dies at next
    /// launch — and the stored rejection is final. At 6 confirmations,
    /// reorg risk is the accepted trade.
    private func spvPointVerifyIfConfigured(
        _ verdict: OpenCsvVerdict,
        snapshotJson: String,
    ) async throws -> OpenCsvVerdict {
        guard verdict.isVerified, let anchor = verdict.anchor else {
            return verdict
        }
        let (peers, network) = db.read {
            (self.store.spvPeers(tx: $0), self.store.network(tx: $0))
        }
        guard !peers.isEmpty else {
            return verdict
        }
        guard let claim = OpenCsvChainView.anchorClaim(
            fromSnapshotJson: snapshotJson,
            anchor: anchor,
            requiredConfirmations: Self.requiredConfirmations,
        ) else {
            owsFailDebug("verified consignment's anchor is missing from its own snapshot")
            throw OpenCsvPaymentsError.snapshotMissingAnchor(
                height: anchor.height,
                position: anchor.position,
            )
        }
        let config = OpenCsvChainView.SpvConfig(
            network: network,
            peers: peers,
            cacheDir: Self.chainCacheDir(network: network),
        )
        // Network I/O for up to the config timeout: run it off the actor
        // so sends and other verifications can interleave. No wallet
        // handle is involved, so the suspension is hazard-free.
        let spv = try await Self.offActor {
            try OpenCsvChainView.verifyAnchor(config: config, claim: claim)
        }
        if spv.isConfirmed {
            Logger.info(
                "SPV confirmed anchor \(claim.height):\(claim.position) "
                + "(\(spv.confirmations ?? 0) confirmation(s))",
            )
            return verdict
        }
        // Exactly two outcomes prove the claim is a lie; everything else —
        // a lagging tip, confirmations still accruing, an unexpected
        // reason (including one this side fails to decode) — stays
        // retryable, because pod drift must never masquerade as a payment
        // rejection.
        if spv.status == "not_present",
           let reason = spv.reason,
           reason == "txid_mismatch" || reason == "record_not_in_tx" {
            var rejected = OpenCsvVerdict(
                status: "rejected",
                reason: "spv: \(reason)",
                credits: nil,
                coins: nil,
                anchor: nil,
            )
            rejected.chainView = verdict.chainView
            return rejected
        }
        throw OpenCsvPaymentsError.spvUnsettled(status: spv.status, reason: spv.reason)
    }

    /// Sync the self-scan occurrence index, if SPV peers are configured.
    /// Called on app activation (before the verification sweep) and lazily
    /// before the first scan decision of a launch. Failure only logs:
    /// verification then throws "no scan registered" and stays retryable.
    /// The on-disk index resumes from its own tip, so a long first walk
    /// simply makes progress on every foreground until it catches up.
    public func scanSyncIfNeeded() async {
        guard !scanSyncInFlight else {
            return
        }
        let (peers, network, fromHeight) = db.read {
            (self.store.spvPeers(tx: $0), self.store.network(tx: $0), self.store.scanFromHeight(tx: $0))
        }
        guard !peers.isEmpty else {
            return
        }
        scanSyncInFlight = true
        defer { scanSyncInFlight = false }
        let config = OpenCsvChainView.ScanSyncConfig(
            network: network,
            peers: peers,
            cacheDir: Self.chainCacheDir(network: network),
            fromHeight: fromHeight,
            requiredConfirmations: Self.requiredConfirmations,
        )
        do {
            let result = try await Self.offActor {
                try OpenCsvChainView.scanSync(config: config)
            }
            scanSyncedThisLaunch = true
            lastScanSyncSummary = result
            Logger.info(
                "self-scan synced to \(result.tipHeight): \(result.anchors) anchor(s), "
                + "\(result.filtersBytes) filter byte(s), \(result.blocksBytes) block byte(s)",
            )
        } catch {
            Logger.warn("self-scan sync failed; scan verification unavailable until it succeeds: \(error)")
        }
    }

    /// The chain-view cache (CBF headers, filters, and the scan index
    /// under `scan/`), namespaced per network so switching networks can
    /// never replay one chain's cache against another. Caches, not the
    /// group container: everything in it is re-derivable from the
    /// network, and the wallet's real state never lives here.
    private static func chainCacheDir(network: String) -> String {
        let dir = OWSFileSystem.cachesDirectoryPath() + "/OpenCsvCbf/" + network
        _ = OWSFileSystem.ensureDirectoryExists(dir)
        return dir
    }

    /// Run a blocking chain-view FFI call off the actor, so wallet work
    /// can interleave with its network I/O. Only for calls that take no
    /// wallet handle.
    private static func offActor<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T,
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try body() })
            }
        }
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
        assetIdHex: String? = nil,
    ) async throws -> OpenCsvWalletStore.PendingDelivery {
        guard !isSending else {
            throw OpenCsvPaymentsError.sendAlreadyInProgress
        }
        // Reject a malformed key here rather than as an opaque Rust error
        // string surfaced in the UI.
        let recipient = toOwnerHex.lowercased()
        guard recipient.count == 64, recipient.allSatisfy(\.isHexDigit) else {
            throw OpenCsvPaymentsError.malformedRecipient
        }
        isSending = true
        defer { isSending = false }
        let wallet = try await ensureWallet()

        let unspent = try wallet.coins().filter(\.unspent)
        guard !unspent.isEmpty else {
            throw OpenCsvPaymentsError.insufficientFunds(available: 0)
        }
        // Which asset to spend is a decision, not an accident of ordering.
        // With one asset it is unambiguous; with several the caller must
        // say, rather than us silently spending whichever sorted first.
        let assetIds = Set(unspent.map(\.assetId))
        guard let assetId = assetIds.count == 1 ? assetIds.first : assetIdHex else {
            throw OpenCsvPaymentsError.assetNotSpecified(available: assetIds.sorted())
        }
        guard assetIds.contains(assetId) else {
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
            toOwnerHex: recipient,
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
        // Everything below is irreversible or unrecoverable-from-memory, so
        // persist the pending transaction first. The openings carry
        // randomness that cannot be re-derived: without this, a crash
        // between broadcasting the anchor and finalizing spends the coins
        // on-chain and destroys the consignment the recipient needs.
        let inFlightId = UUID().uuidString
        do {
            let exportJson = try wallet.exportPending(pendingId: proved.pendingId)
            try await db.awaitableWrite { tx in
                try self.store.upsertInFlightSend(
                    OpenCsvWalletStore.InFlightSend(
                        id: inFlightId,
                        exportJson: exportJson,
                        threadUniqueId: threadUniqueId,
                        amount: amount,
                        currency: inputs.first?.currency,
                        assetId: assetId,
                        createdAt: Date(),
                    ),
                    tx: tx,
                )
            }
        } catch {
            // Refuse to anchor what we could not learn to recover.
            throw OpenCsvPaymentsError.couldNotPersistPendingSend(underlying: "\(error)")
        }

        let anchorRef = try await provider.publishAnchor(
            recordHex: recordHex,
            ctxHex: ctxHex,
            onBroadcast: { txid in
                // Spent from this moment, confirmed or not.
                try? await self.db.awaitableWrite { tx in
                    var broadcast = OpenCsvWalletStore.InFlightSend(
                        id: inFlightId,
                        exportJson: (try? wallet.exportPending(pendingId: proved.pendingId)) ?? "",
                        threadUniqueId: threadUniqueId,
                        amount: amount,
                        currency: inputs.first?.currency,
                        assetId: assetId,
                        createdAt: Date(),
                    )
                    broadcast.txidHex = txid
                    try self.store.upsertInFlightSend(broadcast, tx: tx)
                }
            },
        )
        // Record where it landed, so a crash before finalize can resume.
        try? await db.awaitableWrite { tx in
            guard var send = self.store.inFlightSends(tx: tx).first(where: { $0.id == inFlightId }) else { return }
            send.txidHex = anchorRef.txid
            send.height = anchorRef.height
            send.position = anchorRef.position
            try self.store.upsertInFlightSend(send, tx: tx)
        }
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
            // The consignment now exists and is durably queued, so the
            // recovery record has done its job.
            try self.store.removeInFlightSend(id: inFlightId, tx: tx)
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

    /// Finish sends interrupted between anchoring and finalizing.
    ///
    /// A record with no txid was never broadcast — nothing was spent, so it
    /// is simply dropped. One with a txid may have anchored, so the export
    /// is re-imported and finalized against the confirmed anchor, turning a
    /// lost payment back into a deliverable one.
    public func recoverInterruptedSends() async {
        let sends = db.read { self.store.inFlightSends(tx: $0) }
        guard !sends.isEmpty else { return }
        guard let wallet = try? await ensureWallet() else { return }

        for send in sends {
            guard let txidHex = send.txidHex, let height = send.height, let position = send.position else {
                Logger.info("dropping OpenCSV send \(send.id): never broadcast, nothing was spent")
                try? await db.awaitableWrite { tx in try self.store.removeInFlightSend(id: send.id, tx: tx) }
                continue
            }
            do {
                let pendingId = try wallet.importPending(json: send.exportJson)
                let (blob, spends) = try wallet.finalize(
                    pendingId: pendingId,
                    anchorRef: OpenCsvAnchorRef(txid: txidHex, height: height, position: position),
                )
                let body = OpenCsvAttachmentDetector.outgoingBody(byteCount: blob.count)
                try await db.awaitableWrite { tx in
                    let entry = try self.store.recordOutgoing(blob: blob, spends: spends, tx: tx)
                    try self.store.addPendingDelivery(
                        OpenCsvWalletStore.PendingDelivery(
                            threadUniqueId: send.threadUniqueId,
                            body: body,
                            replayEntry: entry,
                            amount: send.amount,
                            currency: send.currency,
                            assetId: send.assetId,
                            createdAt: Date(),
                        ),
                        tx: tx,
                    )
                    try self.store.removeInFlightSend(id: send.id, tx: tx)
                }
                Logger.info("recovered interrupted OpenCSV send \(send.id) from its export")
            } catch {
                Logger.warn("could not recover OpenCSV send \(send.id) yet: \(error)")
            }
        }
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
            spvPeers: db.read { store.spvPeers(tx: $0) },
            network: db.read { store.network(tx: $0) },
        )
    }

    public func setAnchorServerUrl(_ urlString: String?) async {
        await db.awaitableWrite { tx in
            self.store.setAnchorServerUrl(urlString, tx: tx)
        }
    }

    public func setSpvPeers(_ peers: [String]) async {
        do {
            try await db.awaitableWrite { tx in
                try self.store.setSpvPeers(peers, tx: tx)
            }
        } catch {
            // A lost settings write is recoverable (retype it), but it must
            // not be silent: without peers, self-scan and SPV never run.
            Logger.error("could not persist SPV peers: \(error)")
        }
    }

    public func setNetwork(_ network: String) async {
        await db.awaitableWrite { tx in
            self.store.setNetwork(network, tx: tx)
        }
        // The scan index and header cache are per-network; a change makes
        // any synced state meaningless until the next sync.
        scanSyncedThisLaunch = false
    }

    /// A stored verdict, for the conversation cell (main-thread render path).
    public nonisolated func verdict(attachmentId: Attachment.IDType, tx: DBReadTransaction) -> OpenCsvVerdictRecord? {
        OpenCsvWalletStore(keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage)
            .verdict(attachmentId: attachmentId, tx: tx)
    }

    // MARK: - Explorer (the phone-as-explorer detail sheet)

    /// Everything the tap-through detail sheet shows: the stored verdict
    /// (authoritative), the chain evidence derived live from the phone's
    /// own view, and what that view cost to build. Read-only — deriving
    /// detail never writes a verdict.
    public struct ExplorerDetail {
        public let verdict: OpenCsvVerdictRecord?
        /// Last withheld (retryable) failure, when no verdict exists yet.
        public let withheldReason: String?
        /// Chain evidence, present when it could be derived live.
        public let anchorHeight: UInt64?
        public let anchorPosition: UInt32?
        public let txidHex: String?
        public let recordHex: String?
        public let ctxHex: String?
        /// Confirmations of the anchor against the phone's current tip.
        public let confirmations: UInt64?
        public let tipHeight: UInt64?
        /// The last scan sync's counters (nil before the first sync).
        public let syncSummary: OpenCsvChainView.ScanSyncResult?
        public let network: String
        /// The stored consignment blob, for the share/open row.
        public let blob: Data?
    }

    /// Build the detail sheet's model. Chain evidence is derived at
    /// tap-time by re-verifying the stored blob against the scan-index
    /// snapshot — always-fresh confirmations, works for old verdicts, and
    /// the stored verdict stays authoritative regardless of the outcome.
    public func explorerDetail(attachmentId: Attachment.IDType) async -> ExplorerDetail {
        let (record, blob, network) = db.read { tx in
            (
                self.store.verdict(attachmentId: attachmentId, tx: tx),
                self.store.replayBlobs(tx: tx).first { $0.entry == "a:\(attachmentId)" }?.blob,
                self.store.network(tx: tx),
            )
        }
        var anchor: OpenCsvVerdict.Anchor?
        var txid: String?
        var recordHex: String?
        var ctx: String?
        var confirmations: UInt64?
        var tip: UInt64?
        if let blob, let wallet = try? await ensureWallet() {
            if !scanSyncedThisLaunch {
                await scanSyncIfNeeded()
            }
            if let snapshot = try? OpenCsvChainView.exportScanSnapshot(),
               let verdict = try? wallet.verify(
                blob: blob,
                snapshotJson: snapshot,
                requiredConfirmations: 0,
               ),
               let liveAnchor = verdict.anchor {
                anchor = liveAnchor
                if let entry = OpenCsvChainView.snapshotEntryDetails(
                    fromSnapshotJson: snapshot,
                    anchor: liveAnchor,
                ) {
                    txid = entry.txidHex
                    recordHex = entry.recordHex
                    ctx = entry.ctxHex
                }
                tip = lastScanSyncSummary?.tipHeight
                if let tip, tip >= liveAnchor.height {
                    confirmations = tip - liveAnchor.height + 1
                }
            }
        }
        return ExplorerDetail(
            verdict: record,
            withheldReason: record == nil ? lastWithheldReason[attachmentId] : nil,
            anchorHeight: anchor?.height,
            anchorPosition: anchor?.position,
            txidHex: txid,
            recordHex: recordHex,
            ctxHex: ctx,
            confirmations: confirmations,
            tipHeight: tip,
            syncSummary: lastScanSyncSummary,
            network: network,
            blob: blob,
        )
    }

    /// The explorer's "Re-verify now": a fresh sync plus a fresh scan
    /// decision on the stored blob. Read-only — reports what the chain
    /// says right now; the stored verdict is not rewritten.
    public func reVerify(attachmentId: Attachment.IDType) async throws -> Bool {
        guard let blob = db.read(block: { tx in
            self.store.replayBlobs(tx: tx).first { $0.entry == "a:\(attachmentId)" }?.blob
        }) else {
            throw OpenCsvPaymentsError.consignmentSizeRejected(bytes: 0)
        }
        let wallet = try await ensureWallet()
        await scanSyncIfNeeded()
        let scanned = try OpenCsvChainView.scanVerify(wallet: wallet, consignment: blob)
        return scanned.isVerified
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

        // Rebuilding coins needs a chain view. Falling back to "no
        // snapshot, no replay" would present an empty wallet as if it were
        // genuinely empty, so try the network before giving up and say so
        // loudly if there is still nothing to replay against.
        var snapshot = cachedSnapshot
        if snapshot == nil, !replay.isEmpty {
            snapshot = try? await fetchAndCacheSnapshot()
            if snapshot == nil {
                Logger.error(
                    "no anchor snapshot available: \(replay.count) stored consignment(s) cannot be "
                    + "replayed, so balances will read as empty until one is reachable",
                )
            }
        }

        if let snapshot {
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
        }

        // Re-apply spend state unconditionally, and one id at a time: the
        // FFI call is all-or-nothing, so a single id the wallet does not
        // know (its consignment failed to replay) would otherwise leave
        // *every* spent coin looking spendable — a double-spend waiting to
        // happen.
        var unmarked: [String] = []
        for coinId in spent {
            do {
                try wallet.markSpent(coinIds: [coinId])
            } catch {
                unmarked.append(coinId)
            }
        }
        if !unmarked.isEmpty {
            Logger.warn("could not mark \(unmarked.count) spent coin(s); they are not in the wallet")
        }

        self.wallet = wallet
        return wallet
    }

    private func fetchAndCacheSnapshot() async throws -> String {
        // Serverless first: when the phone has its own chain view, the
        // crediting snapshot comes from the scan index — no server asked,
        // and the tip agrees with the scan's own confirmation counting.
        // Cached like any snapshot so offline startup replay keeps working.
        let peers = db.read { self.store.spvPeers(tx: $0) }
        if !peers.isEmpty {
            if !scanSyncedThisLaunch {
                await scanSyncIfNeeded()
            }
            if scanSyncedThisLaunch {
                do {
                    let snapshot = try OpenCsvChainView.exportScanSnapshot()
                    await db.awaitableWrite { tx in
                        self.store.setLastSnapshotJson(snapshot, tx: tx)
                    }
                    return snapshot
                } catch {
                    Logger.warn("scan-index snapshot export failed; falling back to server/cache: \(error)")
                }
            }
        }
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
