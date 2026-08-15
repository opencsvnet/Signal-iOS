//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public extension Notification.Name {
    /// Durable OpenCSV state now needs a BackgroundTasks scheduling pass.
    /// The notification is only a wake-up hint; the runner always derives its
    /// actual decision from the database so losing this post is harmless.
    static let openCsvBackgroundWorkNeedsScheduling = Notification.Name(
        "OpenCsvBackgroundWorkNeedsScheduling",
    )
}

/// User-facing failures of the OpenCSV payment flows.
public enum OpenCsvPaymentsError: Error {
    /// Signal Secure Backup is disabled or being disabled. Bitcoin-writing
    /// operations remain frozen until a current wallet checkpoint is backed
    /// up successfully.
    case secureBackupRequired
    /// A wallet checkpoint could not be included in a completed Signal
    /// Secure Backup, so the corresponding operation was not signed.
    case secureBackupFailed(underlying: String)
    /// The Rust-owned operation reached a durable state but its consignment
    /// is not independently observed and ready for Signal delivery yet.
    case consignmentNotReady(operationId: String, state: String)
    /// The RBF replacement is already signed/persisted/broadcast, but the
    /// refreshed operation journal has not yet reached Secure Backup. The
    /// UI must report this as committed and must not blindly retry it.
    case feeBumpCommittedBackupPending(operationId: String, txid: String?)
    /// A linked device has not yet received its public watch descriptors.
    case linkedWalletNotProvisioned
    /// The wallet holds fewer than the two spendable coins a transfer needs.
    case needTwoCoins
    /// Unspent total is below the requested amount.
    case insufficientFunds(available: UInt64)
    /// Another send is mid-flight; its coins are not yet marked spent.
    case sendAlreadyInProgress
    /// No confirmed, unreserved Bitcoin output can fund an OpenCSV anchor.
    /// The Rust wallet remains the authority; this typed error keeps its
    /// stable rejection reason out of user-facing UI copy.
    case feeReserveRequired(minimumSats: UInt64, confirmedSats: UInt64)
    /// Nominal USD is sufficient only by combining issuer-specific claims.
    /// Version one never silently mixes those claims in one transfer.
    case issuerSplitRequired(totalAvailable: UInt64)
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
    /// Mandatory phone-owned chain evidence is temporarily unavailable or
    /// still catching up. The exact durable send remains queued and must be
    /// retried; this is never a terminal payment failure.
    case chainVerificationUnavailable
    /// Bitcoin descriptors, checkpoints, and compact-filter caches are all
    /// chain-specific. Changing the network of an existing account would
    /// either strand it behind Rust's network guard or mix test histories.
    case networkChangeRequiresIsolatedWallet(current: String, requested: String)
    /// The account wallet supports only chains with authoritative CBF
    /// verification wired through this integration.
    case unsupportedNetwork(String)
    /// Mainnet remains unavailable until this exact app build contains at
    /// least one reviewed, non-test USD issuer manifest. Test USD must never
    /// be reinterpreted as a production instrument.
    case productionUsdNotConfigured
}

/// One exact issuer instrument selected to satisfy a USD send. The UI shows
/// the issuer before confirmation and the receipt preserves the asset id.
public struct OpenCsvUsdSendSelection: Equatable {
    public let credit: OpenCsvCredit
    public let instrument: OpenCsvInstrumentRecord
}

/// Coarse, user-meaningful stages of a Signal payment. These deliberately
/// describe work rather than exposing Rust journal states or chain jargon.
public enum OpenCsvSendProgress: Sendable {
    case checkingWallet
    case generatingProof
    case protectingRecovery
    case broadcasting
}

/// The OpenCSV payments service: owns the Rust account wallet and runs the
/// receive pipeline (consignment attachment → verify → verdict → re-render)
/// and the wallet half of the send pipeline (prove → publish anchor →
/// finalize → persist). Transport stays with the caller: the send UI
/// enqueues the returned blob through the normal message pipeline.
///
/// An actor: FFI wallet handles are not thread-safe, and the production
/// first-hop transfer receipt measured 11.253 s on the iPhone 16e, so all
/// wallet work is serialized off the main thread here.
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

    enum IncomingConsignmentAdmission: Equatable {
        case inspect
        case rejectSize
    }

    /// Apply the same cheap pre-download size decision in every receive
    /// entry point. Missing metadata still uses Signal's normal automatic
    /// download policy and is bounded again after decryption.
    static func incomingConsignmentAdmission(
        advertisedByteCount: UInt64?,
    ) -> IncomingConsignmentAdmission {
        guard let advertisedByteCount else { return .inspect }
        return advertisedByteCount > 0 && advertisedByteCount <= UInt64(maxConsignmentBytes)
            ? .inspect
            : .rejectSize
    }

    /// Attachment-shaped payment traffic is not a user gesture and must not
    /// bypass Signal's normal download, call, or message-request policy.
    static let automaticConsignmentDownloadPriority: AttachmentDownloadPriority = .default

    static func shouldNotifyTerminalIncomingRejection(
        priorActivityState: OpenCsvIncomingActivityState?,
    ) -> Bool {
        priorActivityState != .needsAttention
    }

    /// Rust's minimum value for the first, context-binding funding input.
    /// Keep this pinned by tests until the account status schema exposes the
    /// policy value directly.
    public static let minimumFeeReserveSats: UInt64 = 2_500

    private var wallet: OpenCsvWallet?
    /// Durable Signal-native account. This owns the Bitcoin fee wallet,
    /// protocol keys, UTXO reservations, signed transactions, and operation
    /// journal. The legacy in-memory wallet above remains receive-only while
    /// stored prototype consignments are migrated.
    private var accountWallet: OpenCsvAccountWallet?
    /// Set for the duration of a send. `sendPayment` releases the actor at
    /// every `await` (context reservation, anchor confirmation), so without
    /// this two concurrent sends would both read the same unspent set and
    /// select the same two coins.
    private var isSending = false
    /// Delivery ids currently being handed to the send pipeline, so a
    /// foreground sweep cannot re-send one that is already in flight.
    private var deliveriesInFlight = Set<String>()
    /// Attachment downloads can converge onto the same deduplicated Signal
    /// attachment row. Coalesce them at this actor boundary so one payment does
    /// not repeat the expensive chain scan while its first verification is
    /// suspended on network I/O.
    private var verificationsInFlight = Set<Attachment.IDType>()
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
    /// Every foreground screen, attachment verifier, and background task
    /// joins the same phone-owned chain update. Treating "already running" as
    /// a failure made a foreground wallet opened during background work show
    /// a false update error even though the shared scan was healthy.
    private var scanSyncTask: Task<Bool, Never>?
    /// Persistent CBF client: one handshake, reused connections. Nil
    /// until the first successful open; dropped (and re-opened next
    /// sync) on any error or on a network/peers change.
    private var cbfClientId: UInt64?
    /// The configuration the client was opened with — a change means the
    /// connections point at the wrong chain or the wrong peers.
    private var cbfClientConfig: (network: String, peers: [String])?

    private var db: any DB { DependenciesBridge.shared.db }
    private var attachmentStore: AttachmentStore { DependenciesBridge.shared.attachmentStore }
    private var store: OpenCsvWalletStore {
        OpenCsvWalletStore(keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage)
    }

    /// What the settings/send UI needs to render.
    public struct WalletSummary: Codable, Equatable {
        /// When this exact read-only presentation was persisted. It is not a
        /// chain-verification time and never participates in spend policy.
        public let cachedAt: Date
        /// The wallet's receiving key (share with senders and external issuers).
        public let owner: String
        public let balances: [OpenCsvCredit]
        /// Incoming transport/finality state. Confirming entries are not in
        /// balances. Available-unconfirmed entries are real Rust-selected
        /// coins whose exact parent transaction is rechecked before signing.
        public let incomingActivities: [OpenCsvIncomingActivity]
        public let instruments: [OpenCsvInstrumentRecord]
        public let operations: [OpenCsvAccountOperationSummary]
        public let feeReserve: OpenCsvAccountStatus.FeeReserve
        public let batchReserves: OpenCsvAccountStatus.BatchReserves?
        public let bitcoinDepositAddress: String
        public let backupVerified: Bool
        public let writeEnabled: Bool
        public let accountRole: OpenCsvAccountRole
        public let deviceBindingStatus: String
        public let syncProvenance: OpenCsvAccountStatus.SyncProvenance
        /// Last completed phone-owned headers/BIP158/verified-block sync.
        /// Nil on installs that predate the persisted receipt or have not yet
        /// completed their first scan.
        public let verifiedChainView: OpenCsvVerifiedChainView?
        public let esploraUrl: URL?
        /// Bitcoin P2P peers powering self-scan and SPV point-verify.
        public let spvPeers: [String]
        /// Earliest height the phone-owned marker scan must cover. This is
        /// asset/wallet provenance, not the current sync tip.
        public let scanFromHeight: UInt64
        /// Bitcoin network for the chain views ("signet" default).
        public let network: String
        /// Application deployment namespace; distinct from the Bitcoin
        /// network and shown so archived v1 state cannot look current.
        public let deploymentId: String
        /// Reviewed check definitions with the user's persisted per-check
        /// Off / Observe / Require selections.
        public let observationPolicy: [OpenCsvObservationCheck]
        /// Number of required raw API checks that must succeed. All enabled
        /// checks still produce receipts.
        public let requiredRawObserverQuorum: UInt32
        /// Durable Rust verdicts for recent checks, including timing, cache
        /// age, pin profile and exact-byte comparison.
        public let observationReceipts: [OpenCsvObservationReceipt]
    }

    // MARK: - Receive pipeline

    /// Called (fire-and-forget) when an attachment finishes downloading.
    /// Verifies it iff it is an OpenCSV consignment without a final stored
    /// verdict, then persists the verdict and re-renders owning messages.
    /// Legacy chain-lag rejections remain eligible so installs that once
    /// persisted AnchorNotFound can repair themselves after the chain catches
    /// up.
    ///
    /// Infrastructure failures (no snapshot reachable, wallet unavailable)
    /// store nothing, so a later retry can still verify; only a definitive
    /// prover accept/reject is persisted.
    public func verifyDownloadedAttachmentIfNeeded(attachmentId: Attachment.IDType) async {
        guard verificationsInFlight.insert(attachmentId).inserted else {
            Logger.info("coalesced duplicate OpenCSV verification for consignment \(attachmentId)")
            return
        }
        defer { verificationsInFlight.remove(attachmentId) }

        struct Candidate {
            let stream: AttachmentStream
            let threadUniqueId: String?
            let messageUniqueId: String?
        }
        let candidate: Candidate? = db.read { tx in
            guard
                Self.shouldRetryStoredVerdict(
                    store.verdict(attachmentId: attachmentId, tx: tx),
                )
            else {
                return nil
            }
            guard let stream = attachmentStore.fetch(id: attachmentId, tx: tx)?.asStream() else {
                return nil
            }
            var isConsignment = false
            var threadUniqueId: String?
            var messageUniqueId: String?
            attachmentStore.enumerateAllReferences(toAttachmentId: attachmentId, tx: tx) { reference, _ in
                if
                    OpenCsvAttachmentDetector.isConsignment(
                        sourceFilename: reference.sourceFilename,
                        mimeType: stream.mimeType,
                        // Resolved, not nil: a consignment whose filename was
                        // stripped is recognised only by its body marker, and
                        // skipping it here would leave it unverified until the
                        // user happened to open the wallet.
                        bodyText: OpenCsvAttachmentDetector.owningMessageBody(of: reference, tx: tx),
                    )
                {
                    isConsignment = true
                }
                if
                    threadUniqueId == nil,
                    case .message(let messageSource) = reference.owner,
                    let interaction = DependenciesBridge.shared.interactionStore.fetchInteraction(
                        rowId: messageSource.messageRowId,
                        tx: tx,
                    ) as? TSIncomingMessage
                {
                    threadUniqueId = interaction.uniqueThreadId
                    messageUniqueId = interaction.uniqueId
                }
            }
            return isConsignment ? Candidate(
                stream: stream,
                threadUniqueId: threadUniqueId,
                messageUniqueId: messageUniqueId,
            ) : nil
        }
        guard let candidate else { return }

        guard
            Self.incomingConsignmentAdmission(
                advertisedByteCount: UInt64(candidate.stream.unencryptedByteCount),
            ) == .inspect
        else {
            await rejectIncomingAttachment(
                attachmentId: attachmentId,
                threadUniqueId: candidate.threadUniqueId,
                messageUniqueId: candidate.messageUniqueId,
                reason: "consignment_size_rejected",
            )
            return
        }

        let blob: Data
        do {
            blob = try candidate.stream.decryptedRawData()
        } catch {
            Logger.warn("could not read consignment attachment: \(error)")
            return
        }

        let inspection: OpenCsvConsignmentInspection
        do {
            inspection = try await inspectIncomingConsignment(blob)
        } catch {
            if let rejectionReason = Self.terminalIncomingRejectionReason(error) {
                await rejectIncomingAttachment(
                    attachmentId: attachmentId,
                    threadUniqueId: candidate.threadUniqueId,
                    messageUniqueId: candidate.messageUniqueId,
                    reason: rejectionReason,
                )
            } else {
                lastWithheldReason[attachmentId] = "\(error)"
                Logger.warn("could not inspect consignment \(attachmentId): \(error)")
            }
            return
        }
        if let rejectionReason = Self.receiverAssetRejectionReason(inspection) {
            await rejectIncomingAttachment(
                attachmentId: attachmentId,
                threadUniqueId: candidate.threadUniqueId,
                messageUniqueId: candidate.messageUniqueId,
                reason: rejectionReason,
            )
            return
        }

        let priorActivityState = db.read { tx in
            self.store.incomingActivities(tx: tx)
                .first { $0.attachmentId == attachmentId }?
                .state
        }
        if priorActivityState == nil {
            try? await db.awaitableWrite { tx in
                try self.store.upsertIncomingActivity(
                    attachmentId: attachmentId,
                    threadUniqueId: candidate.threadUniqueId,
                    messageUniqueId: candidate.messageUniqueId,
                    state: .confirming,
                    tx: tx,
                )
            }
            // Publish the pending transition as soon as it is durable. The
            // same replacement identifier is used by the later available or
            // needs-attention transition, so a fast verification does not
            // leave two notifications behind.
            notifyPaymentStatus(
                threadUniqueId: candidate.threadUniqueId,
                messageUniqueId: candidate.messageUniqueId,
                body: OWSLocalizedString(
                    "OPENCSV_NOTIFICATION_CONFIRMING",
                    comment: "Notification that an incoming OpenCSV payment is confirming and is not spendable yet.",
                ),
                wantsSound: false,
            )
            requestBackgroundWorkScheduling()
        }

        do {
            let verdict = try await verifyBlobWithConfiguredChainView(blob, inspection: inspection)
            let record = OpenCsvVerdictRecord(verdict: verdict, date: Date())
            await db.awaitableWrite { tx in
                self.store.setVerdict(
                    record,
                    blob: blob,
                    attachmentId: attachmentId,
                    messageUniqueId: candidate.messageUniqueId,
                    tx: tx,
                )
                do {
                    switch record.direction {
                    case .incoming where record.isVerified:
                        try self.store.upsertIncomingActivity(
                            attachmentId: attachmentId,
                            threadUniqueId: candidate.threadUniqueId,
                            messageUniqueId: candidate.messageUniqueId,
                            state: record.finality == "unconfirmed" ? .availableUnconfirmed : .settled,
                            amount: record.amount,
                            currency: record.currency,
                            tx: tx,
                        )
                    case .thirdParty where record.isVerified:
                        try self.store.removeIncomingActivity(attachmentId: attachmentId, tx: tx)
                    default:
                        try self.store.upsertIncomingActivity(
                            attachmentId: attachmentId,
                            threadUniqueId: candidate.threadUniqueId,
                            messageUniqueId: candidate.messageUniqueId,
                            state: .needsAttention,
                            amount: record.amount > 0 ? record.amount : nil,
                            currency: record.currency,
                            detail: record.reason,
                            tx: tx,
                        )
                    }
                } catch {
                    owsFailDebug("could not persist OpenCSV incoming activity: \(error)")
                }
                self.touchOwners(attachmentId: attachmentId, tx: tx)
            }
            lastWithheldReason[attachmentId] = nil
            let acceptedState: OpenCsvIncomingActivityState = record.finality == "unconfirmed"
                ? .availableUnconfirmed
                : .settled
            if record.direction == .incoming, record.isVerified, priorActivityState != acceptedState {
                let notificationFormat = record.finality == "unconfirmed"
                    ? OWSLocalizedString(
                        "OPENCSV_NOTIFICATION_AVAILABLE_UNCONFIRMED_FORMAT",
                        comment: "Notification that a verified OpenCSV payment is spendable before confirmation. Embeds the amount and currency.",
                    )
                    : OWSLocalizedString(
                        "OPENCSV_NOTIFICATION_SETTLED_FORMAT",
                        comment: "Notification that an OpenCSV payment reached settlement depth. Embeds the amount and currency.",
                    )
                notifyPaymentStatus(
                    threadUniqueId: candidate.threadUniqueId,
                    messageUniqueId: candidate.messageUniqueId,
                    body: String.nonPluralLocalizedStringWithFormat(
                        notificationFormat,
                        OpenCsvUsdAmount.format(record.amount),
                        record.presentationCurrency,
                    ),
                    wantsSound: true,
                )
            } else if
                !record.isVerified,
                Self.shouldNotifyTerminalIncomingRejection(
                    priorActivityState: priorActivityState,
                )
            {
                notifyPaymentStatus(
                    threadUniqueId: candidate.threadUniqueId,
                    messageUniqueId: candidate.messageUniqueId,
                    body: OWSLocalizedString(
                        "OPENCSV_NOTIFICATION_NEEDS_ATTENTION",
                        comment: "Notification that an OpenCSV payment could not be accepted.",
                    ),
                    wantsSound: false,
                )
            }
            Logger.info(
                "consignment \(attachmentId): \(record.status)"
                    + (record.reason.map { " (\($0))" } ?? "")
                    + " via \(record.chainView ?? "?")",
            )
        } catch {
            lastWithheldReason[attachmentId] = "\(error)"
            let wasUnconfirmedCredit = priorActivityState == .availableUnconfirmed
                || priorActivityState == .awaitingObservers
            let lostUnconfirmedParent = wasUnconfirmedCredit
                && Self.isUnconfirmedParentFailure(error)
            if
                let paymentError = error as? OpenCsvPaymentsError,
                case .chainViewLagging = paymentError
            {
                try? await db.awaitableWrite { tx in
                    try self.store.upsertIncomingActivity(
                        attachmentId: attachmentId,
                        threadUniqueId: candidate.threadUniqueId,
                        messageUniqueId: candidate.messageUniqueId,
                        state: wasUnconfirmedCredit ? .awaitingObservers : .confirming,
                        detail: "awaiting verified chain settlement",
                        tx: tx,
                    )
                }
            } else if let rejectionReason = Self.terminalIncomingRejectionReason(error) {
                var verdict = OpenCsvVerdict(
                    status: "rejected",
                    reason: rejectionReason,
                    credits: nil,
                    coins: nil,
                    anchor: nil,
                )
                verdict.chainView = "local-consignment-decoder"
                let record = OpenCsvVerdictRecord(verdict: verdict, date: Date())
                await db.awaitableWrite { tx in
                    self.store.setVerdict(
                        record,
                        blob: blob,
                        attachmentId: attachmentId,
                        messageUniqueId: candidate.messageUniqueId,
                        tx: tx,
                    )
                    do {
                        try self.store.upsertIncomingActivity(
                            attachmentId: attachmentId,
                            threadUniqueId: candidate.threadUniqueId,
                            messageUniqueId: candidate.messageUniqueId,
                            state: .needsAttention,
                            detail: rejectionReason,
                            tx: tx,
                        )
                    } catch {
                        owsFailDebug("could not persist malformed OpenCSV activity: \(error)")
                    }
                    self.touchOwners(attachmentId: attachmentId, tx: tx)
                }
                lastWithheldReason[attachmentId] = nil
                if
                    Self.shouldNotifyTerminalIncomingRejection(
                        priorActivityState: priorActivityState,
                    )
                {
                    notifyPaymentStatus(
                        threadUniqueId: candidate.threadUniqueId,
                        messageUniqueId: candidate.messageUniqueId,
                        body: OWSLocalizedString(
                            "OPENCSV_NOTIFICATION_NEEDS_ATTENTION",
                            comment: "Notification that an OpenCSV payment could not be accepted.",
                        ),
                        wantsSound: false,
                    )
                }
                Logger.info(
                    "consignment \(attachmentId): rejected (\(rejectionReason))"
                        + " via local-consignment-decoder",
                )
                return
            } else if lostUnconfirmedParent {
                try? await db.awaitableWrite { tx in
                    try self.store.upsertIncomingActivity(
                        attachmentId: attachmentId,
                        threadUniqueId: candidate.threadUniqueId,
                        messageUniqueId: candidate.messageUniqueId,
                        state: .needsAttention,
                        detail: "unconfirmed parent disappeared or was replaced",
                        tx: tx,
                    )
                }
                notifyPaymentStatus(
                    threadUniqueId: candidate.threadUniqueId,
                    messageUniqueId: candidate.messageUniqueId,
                    body: OWSLocalizedString(
                        "OPENCSV_NOTIFICATION_UNCONFIRMED_CHANGED",
                        comment: "Notification that a zero-confirmation payment dependency disappeared or was replaced.",
                    ),
                    wantsSound: false,
                )
            } else if wasUnconfirmedCredit {
                // Required observer evidence is intentionally live, not a
                // one-time admission token. If a provider is unavailable or
                // no longer agrees, Rust freezes descendant coin selection.
                // Mirror that policy in Signal without erasing the already
                // verified amount or claiming a definitive rejection.
                try? await db.awaitableWrite { tx in
                    try self.store.upsertIncomingActivity(
                        attachmentId: attachmentId,
                        threadUniqueId: candidate.threadUniqueId,
                        messageUniqueId: candidate.messageUniqueId,
                        state: .awaitingObservers,
                        detail: "waiting for required network verification",
                        tx: tx,
                    )
                }
            }
            Logger.warn("consignment \(attachmentId) not verifiable yet: \(error)")
        }
    }

    private nonisolated func notifyPaymentStatus(
        threadUniqueId: String?,
        messageUniqueId: String?,
        body: String,
        wantsSound: Bool,
    ) {
        guard let threadUniqueId, let messageUniqueId else { return }
        SSKEnvironment.shared.notificationPresenterRef.notifyUserOfOpenCsvPaymentStatus(
            threadUniqueId: threadUniqueId,
            messageUniqueId: messageUniqueId,
            body: body,
            wantsSound: wantsSound,
        )
    }

    /// Local completion signal for a payment whose proof/broadcast worker
    /// finished after the send sheet had already closed.
    public nonisolated func notifyOutgoingPaymentDelivered(
        threadUniqueId: String,
        messageUniqueId: String,
        amount: UInt64,
        currency: String?,
        assetId: String?,
    ) {
        let productName = OpenCsvProductPresentation.currencyName(currency: currency, assetId: assetId)
        notifyPaymentStatus(
            threadUniqueId: threadUniqueId,
            messageUniqueId: messageUniqueId,
            body: "OpenCSV payment sent: \(OpenCsvUsdAmount.format(amount)) \(productName)",
            wantsSound: false,
        )
    }

    private nonisolated func requestBackgroundWorkScheduling() {
        NotificationCenter.default.post(name: .openCsvBackgroundWorkNeedsScheduling, object: nil)
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
        let inspection = try await inspectIncomingConsignment(blob)
        return try await verifyBlobWithConfiguredChainView(blob, inspection: inspection)
    }

    private func verifyBlobWithConfiguredChainView(
        _ blob: Data,
        inspection: OpenCsvConsignmentInspection,
    ) async throws -> OpenCsvVerdict {
        let account = try await ensureAccountWallet()
        if let rejectionReason = Self.receiverAssetRejectionReason(inspection) {
            var verdict = OpenCsvVerdict(
                status: "rejected",
                reason: rejectionReason,
                credits: nil,
                coins: nil,
                anchor: nil,
            )
            verdict.chainView = "local-reviewed-asset-policy"
            return verdict
        }
        let (peers, indexers) = db.read { tx in
            let network = self.store.network(tx: tx)
            return (
                Self.effectiveSpvPeers(
                    configured: self.store.spvPeers(tx: tx),
                    network: network,
                ),
                self.store.indexerUrls(tx: tx),
            )
        }

        let plan = Self.chainViewPlan(peerCount: peers.count, indexerCount: indexers.count)
        var settlementLagReason: String?
        switch plan {
        case .selfScan:
            // The phone's own filter-synced occurrence index; no server is
            // asked and none is believed. An unsynced index throws — a
            // weaker view must never be substituted silently.
            if !scanSyncedThisLaunch {
                await scanSyncIfNeeded()
            }
            var scanned = try OpenCsvChainView.scanVerify(account: account, consignment: blob)
            if !scanned.isVerified, Self.isChainLagReason(scanned.reason) {
                // A payment message routinely beats the chain view by
                // seconds: the anchor exists, the index just hasn't seen
                // it. One fresh (resumed, cheap) sync and retry before
                // any verdict is allowed to exist.
                await scanSyncIfNeeded()
                scanned = try OpenCsvChainView.scanVerify(account: account, consignment: blob)
            }
            guard scanned.isVerified else {
                if Self.isChainLagReason(scanned.reason) {
                    // A confirmed-only scan cannot see mempool anchors. Keep
                    // its settled history as the exclusion prefix and let
                    // the account wallet attempt the distinct exact-txid
                    // provisional capability below.
                    settlementLagReason = scanned.reason
                    break
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
                account: account,
                backends: indexers.map { .http(url: $0) },
                consignment: blob,
                requiredConfirmations: Self.requiredConfirmations,
            )
            if crossChecked.isTipDisagreement {
                // One of these indexers is wrong or lying and we cannot
                // tell which, so no answer here is trustworthy.
                throw OpenCsvPaymentsError.indexersDisagree(tips: crossChecked.tips ?? [])
            }
            let crossCheckReason = crossChecked.reason ?? crossChecked.error
            if !crossChecked.isVerified, Self.isChainLagReason(crossCheckReason) {
                throw OpenCsvPaymentsError.chainViewLagging(reason: crossCheckReason ?? "?")
            }
            guard crossChecked.isVerified else {
                var verdict = OpenCsvVerdict(
                    status: "rejected",
                    reason: crossCheckReason ?? "cross-check rejected",
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
        if !verdict.isVerified, Self.isChainLagReason(verdict.reason) {
            guard plan == .selfScan else {
                throw OpenCsvPaymentsError.chainViewLagging(reason: verdict.reason ?? "?")
            }
            let network = db.read { tx in self.store.network(tx: tx) }
            if network == "signet" {
                let inspection = try account.inspect(blob: blob)
                let observationPolicy = try account.status().observationPolicy
                    ?? db.read { self.store.observationChecks(tx: $0) }
                let observationSet = try await OpenCsvPinnedObserver
                    .observeSignetTransaction(
                        txid: inspection.anchorTxid,
                        policy: observationPolicy,
                    )
                verdict = try account.verifyUnconfirmed(
                    blob: blob,
                    confirmedSnapshotJson: snapshotJson,
                    rawTransaction: observationSet.rawTransaction,
                    observations: observationSet.evidence,
                )
            } else {
                verdict = try account.verifyUnconfirmed(
                    blob: blob,
                    confirmedSnapshotJson: snapshotJson,
                )
            }
            if verdict.isVerified {
                Logger.info(
                    "accepted exact mempool anchor with zero-confirmation dependency"
                        + (settlementLagReason.map { " after settled view reported \($0)" } ?? ""),
                )
            } else {
                Logger.info(
                    "exact mempool anchor remained rejected"
                        + (verdict.reason.map { ": \($0)" } ?? ""),
                )
            }
        }
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

    /// A required raw-transaction observer gates zero-confirmation delivery,
    /// but it must not strand an operation after the phone-owned CBF scan has
    /// independently verified the exact transaction in a block. The Rust SPV
    /// boundary still checks the consignment, headers, PoW, filter match,
    /// full block, Merkle inclusion, and OpenCSV record before settlement.
    static func shouldRefreshOperationSpv(state: String) -> Bool {
        ["broadcast_unobserved", "mempool", "confirmed", "consignment_delivered"].contains(state)
    }

    /// Scan rejections that mean "the chain view hasn't caught up", not
    /// "this payment is bad": never final, always retryable. Pure so the
    /// classification is testable.
    static func isChainLagReason(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason.contains("AnchorNotFound") || reason.contains("InsufficientConfirmations")
    }

    /// Asset admission is a local, deterministic product-policy decision.
    /// Run it before any chain scan so an archived v1 attachment cannot sit
    /// forever in a retry loop merely because its old signet anchor vanished.
    /// The attachment remains in Signal history but is never credited or
    /// relabeled as Test USD v2.
    static func receiverAssetRejectionReason(
        _ inspection: OpenCsvConsignmentInspection,
    ) -> String? {
        guard
            inspection.allAssetsReviewed,
            inspection.unreviewedAssetIds.isEmpty,
            inspection.rejectionReason == nil
        else {
            return "asset_not_reviewed"
        }
        return nil
    }

    /// A canonical decoder failure is immutable input evidence, not chain or
    /// observer lag. Persist it once so archived pre-v2 payloads do not stay
    /// in an infinite "verifying" loop. Match the stable Rust reason prefix,
    /// never arbitrary human-readable detail.
    static func terminalIncomingRejectionReason(_ error: Error) -> String? {
        if
            let paymentError = error as? OpenCsvPaymentsError,
            case .consignmentSizeRejected = paymentError
        {
            return "consignment_size_rejected"
        }
        guard let clientError = error as? OpenCsvClientError else { return nil }
        if clientError.ffiReason == "invalid_consignment" {
            return "invalid_consignment"
        }
        // Compatibility-only errors from the older in-memory FFI do not
        // carry a structured reason. Match their exact stable prefix, never
        // arbitrary detail.
        guard case .ffi(let message) = clientError else { return nil }
        return message == "invalid_consignment" || message.hasPrefix("invalid_consignment:")
            ? "invalid_consignment"
            : nil
    }

    private func rejectIncomingAttachment(
        attachmentId: Attachment.IDType,
        threadUniqueId: String?,
        messageUniqueId: String?,
        reason: String,
    ) async {
        let priorActivityState = db.read { tx in
            self.store.incomingActivities(tx: tx)
                .first { $0.attachmentId == attachmentId }?
                .state
        }
        var verdict = OpenCsvVerdict(
            status: "rejected",
            reason: reason,
            credits: nil,
            coins: nil,
            anchor: nil,
        )
        verdict.chainView = "local-consignment-admission"
        let record = OpenCsvVerdictRecord(verdict: verdict, date: Date())
        await db.awaitableWrite { tx in
            self.store.setVerdict(
                record,
                blob: nil,
                attachmentId: attachmentId,
                messageUniqueId: messageUniqueId,
                tx: tx,
            )
            do {
                try self.store.upsertIncomingActivity(
                    attachmentId: attachmentId,
                    threadUniqueId: threadUniqueId,
                    messageUniqueId: messageUniqueId,
                    state: .needsAttention,
                    detail: reason,
                    tx: tx,
                )
            } catch {
                owsFailDebug("could not persist rejected OpenCSV activity: \(error)")
            }
            self.touchOwners(attachmentId: attachmentId, tx: tx)
        }
        lastWithheldReason[attachmentId] = nil
        if
            Self.shouldNotifyTerminalIncomingRejection(
                priorActivityState: priorActivityState,
            )
        {
            notifyPaymentStatus(
                threadUniqueId: threadUniqueId,
                messageUniqueId: messageUniqueId,
                body: OWSLocalizedString(
                    "OPENCSV_NOTIFICATION_NEEDS_ATTENTION",
                    comment: "Notification that an OpenCSV payment could not be accepted.",
                ),
                wantsSound: false,
            )
        }
    }

    private func inspectIncomingConsignment(_ blob: Data) async throws -> OpenCsvConsignmentInspection {
        guard !blob.isEmpty, blob.count <= Self.maxConsignmentBytes else {
            throw OpenCsvPaymentsError.consignmentSizeRejected(bytes: blob.count)
        }
        let account = try await ensureAccountWallet()
        return try account.inspect(blob: blob)
    }

    /// Retry only verdicts produced before a specific verifier correction.
    /// Version 2 projected batching-v2 members into their proof statements;
    /// version 3 moved chain-view ownership checks from the retired legacy
    /// wallet to the unified account wallet. A current bad proof or genuinely
    /// third-party output remains definitive.
    static func isPreVerifierCorrection(_ verdict: OpenCsvVerdictRecord) -> Bool {
        guard !verdict.isVerified else { return false }
        let version = verdict.verificationVersion ?? 0
        return (version < 2 && verdict.reason?.contains("InvalidProof") == true)
            || (version < 3 && verdict.reason?.contains("NoOwnedOutput") == true)
    }

    /// Nil has never been decided. A historical chain-lag rejection was not a
    /// decision at all, so it must also be retried and may be overwritten by
    /// the later verified verdict. Verified and definitive rejected records
    /// remain stable and are not replayed.
    static func shouldRetryStoredVerdict(_ verdict: OpenCsvVerdictRecord?) -> Bool {
        guard let verdict else { return true }
        return verdict.finality == "unconfirmed"
            || (!verdict.isVerified && isChainLagReason(verdict.reason))
            || isPreVerifierCorrection(verdict)
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
        let account = try await ensureAccountWallet()
        let snapshot = try await fetchAndCacheSnapshot()
        let verdict = try account.verify(blob: blob, snapshotJson: snapshot)
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
        guard verdict.isVerified, verdict.finality != "unconfirmed", let anchor = verdict.anchor else {
            return verdict
        }
        let (peers, network) = db.read { tx in
            let network = self.store.network(tx: tx)
            return (
                Self.effectiveSpvPeers(
                    configured: self.store.spvPeers(tx: tx),
                    network: network,
                ),
                network,
            )
        }
        guard !peers.isEmpty else {
            return verdict
        }
        guard
            let claim = OpenCsvChainView.anchorClaim(
                fromSnapshotJson: snapshotJson,
                anchor: anchor,
                requiredConfirmations: Self.requiredConfirmations,
            )
        else {
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
        if
            spv.status == "not_present",
            let reason = spv.reason,
            reason == "txid_mismatch" || reason == "record_not_in_tx"
        {
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
    @discardableResult
    public func scanSyncIfNeeded() async -> Bool {
        if let scanSyncTask {
            return await scanSyncTask.value
        }
        let task = Task { await self.performScanSync() }
        scanSyncTask = task
        let succeeded = await task.value
        scanSyncTask = nil
        return succeeded
    }

    private func performScanSync() async -> Bool {
        let (peers, network, fromHeight) = db.read { tx in
            let network = self.store.network(tx: tx)
            return (
                Self.effectiveSpvPeers(
                    configured: self.store.spvPeers(tx: tx),
                    network: network,
                ),
                network,
                self.store.scanFromHeight(tx: tx),
            )
        }
        guard !peers.isEmpty else {
            return false
        }
        let config = OpenCsvChainView.ScanSyncConfig(
            network: network,
            peers: peers,
            cacheDir: Self.chainCacheDir(network: network),
            fromHeight: fromHeight,
            requiredConfirmations: Self.requiredConfirmations,
        )
        // Configuration changed since the client was opened: those
        // connections point at the wrong chain or peers.
        if let existing = cbfClientConfig, existing.network != network || existing.peers != peers {
            closeCbfClient()
        }
        do {
            let started = Date()
            let result = try await syncPreferringPersistentClient(config: config)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            scanSyncedThisLaunch = true
            lastScanSyncSummary = result
            try? await db.awaitableWrite { tx in
                try self.store.setVerifiedChainView(
                    OpenCsvVerifiedChainView(tipHeight: result.tipHeight, observedAt: Date()),
                    tx: tx,
                )
            }
            Logger.info(
                "self-scan synced to \(result.tipHeight) in \(elapsedMs) ms"
                    + " (\(cbfClientId != nil ? "persistent" : "one-shot")):"
                    + " \(result.anchors) anchor(s), \(result.filtersBytes) filter byte(s),"
                    + " \(result.blocksBytes) block byte(s)",
            )
            return true
        } catch {
            Logger.warn("self-scan sync failed; scan verification unavailable until it succeeds: \(error)")
            return false
        }
    }

    /// Sync via the persistent client (one handshake ever), opening it on
    /// first use. Any persistent-path error drops the client and falls
    /// back to the one-shot call for this tick — the fast path can never
    /// be a new failure mode.
    private func syncPreferringPersistentClient(
        config: OpenCsvChainView.ScanSyncConfig,
    ) async throws -> OpenCsvChainView.ScanSyncResult {
        if cbfClientId == nil {
            do {
                let clientId = try await Self.offActor {
                    try OpenCsvChainView.openCbfClient(config: config)
                }
                cbfClientId = clientId
                cbfClientConfig = (config.network, config.peers)
            } catch {
                Logger.warn("persistent chain client failed to open; using one-shot sync: \(error)")
            }
        }
        if let clientId = cbfClientId {
            do {
                return try await Self.offActor {
                    try OpenCsvChainView.scanSyncWith(clientId: clientId)
                }
            } catch {
                Logger.warn("persistent sync failed; dropping client and using one-shot: \(error)")
                closeCbfClient()
            }
        }
        return try await Self.offActor {
            try OpenCsvChainView.scanSync(config: config)
        }
    }

    private func closeCbfClient() {
        if let clientId = cbfClientId {
            OpenCsvChainView.closeCbfClient(clientId: clientId)
        }
        cbfClientId = nil
        cbfClientConfig = nil
    }

    /// The chain-view cache (CBF headers, filters, and the scan index
    /// under `scan/`), namespaced per format version and network so
    /// switching networks or changing the reviewed birth-height policy can
    /// never replay a stale scan. Everything here is re-derivable; wallet
    /// state never lives here. The old v1 directory is deliberately left
    /// untouched and ignored so this migration is non-destructive.
    private static func chainCacheDir(network: String) -> String {
        let dir = OWSFileSystem.cachesDirectoryPath() + "/OpenCsvCbf/v2/" + network
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
    /// never got a verdict — e.g. downloaded before chain peers were
    /// configured, or arrived while the download hook could not verify —
    /// verifying downloaded ones and enqueueing downloads for the rest.
    /// Called when the wallet UI opens on a thread.
    /// Retry every consignment still lacking a verdict, across all
    /// conversations.
    ///
    /// Verification needs a settled phone-owned chain view. Peers, generic
    /// accelerators, or confirmations may be unavailable when a consignment
    /// arrives; those attempts store nothing so this activation sweep can
    /// settle them later without trusting a bespoke service.
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

    /// One idempotent maintenance pass suitable for foreground activation or
    /// an iOS BGProcessingTask. The pre-scan sweep starts downloads promptly;
    /// the post-scan sweep promotes or freezes payments whose chain evidence
    /// changed during the update.
    public func performBackgroundMaintenance() async {
        await retryAllPendingVerifications()
        await scanSyncIfNeeded()
        if Task.isCancelled { return }
        await retryAllPendingVerifications()
        if Task.isCancelled { return }
        await refreshOperationSettlementFromVerifiedScan()
        if Task.isCancelled { return }
        await recoverInterruptedSends()
    }

    public func refreshOperationSettlementFromVerifiedScan() async {
        guard scanSyncedThisLaunch, let account = try? await ensureAccountWallet() else { return }
        guard let operations = try? account.operationSummaries() else { return }
        for operation in operations where Self.shouldRefreshOperationSpv(state: operation.state) {
            do {
                _ = try account.refreshOperationSpv(operation.operationId)
            } catch {
                // A scan can be below the anchor or between peer retries.
                // Keep the durable prior state and retry on the next pass.
                Logger.warn("OpenCSV SPV settlement remains pending for \(operation.operationId): \(error)")
            }
        }
    }

    public func retryPendingVerifications(threadUniqueId: String) async {
        struct RejectedAttachment {
            let attachmentId: Attachment.IDType
            let threadUniqueId: String?
            let messageUniqueId: String?
        }
        struct Sweep {
            var verifiable = [Attachment.IDType]()
            var messagesNeedingDownload = [TSMessage]()
            var rejected = [RejectedAttachment]()
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
                            Self.shouldRetryStoredVerdict(
                                store.verdict(attachmentId: referenced.attachment.id, tx: tx),
                            )
                        else {
                            continue
                        }
                        if
                            Self.incomingConsignmentAdmission(
                                advertisedByteCount: referenced.unencryptedByteCount(),
                            ) == .rejectSize
                        {
                            let incoming = message as? TSIncomingMessage
                            sweep.rejected.append(RejectedAttachment(
                                attachmentId: referenced.attachment.id,
                                threadUniqueId: incoming?.uniqueThreadId,
                                messageUniqueId: incoming?.uniqueId,
                            ))
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
                        // Receiving a filename is not a user gesture. Respect
                        // Signal's normal download, call, and message-request
                        // policy instead of bypassing it for wallet traffic.
                        priority: Self.automaticConsignmentDownloadPriority,
                        useThumbnails: false,
                        tx: tx,
                    )
                }
            }
        }
        for rejected in sweep.rejected {
            await rejectIncomingAttachment(
                attachmentId: rejected.attachmentId,
                threadUniqueId: rejected.threadUniqueId,
                messageUniqueId: rejected.messageUniqueId,
                reason: "consignment_size_rejected",
            )
        }
        for attachmentId in sweep.verifiable {
            await verifyDownloadedAttachmentIfNeeded(attachmentId: attachmentId)
        }
    }

    // MARK: - Send pipeline (wallet half)

    /// Durably queue an exact transfer and return before proof generation.
    /// This is the interactive boundary: after it returns, a crash or app
    /// suspension cannot lose the intent, and the conversation may close
    /// while the operation advances through the Rust journal in background.
    public func queuePayment(
        toOwnerHex: String,
        amount: UInt64,
        threadUniqueId: String,
        assetIdHex: String? = nil,
        progress: (@MainActor @Sendable (OpenCsvSendProgress) -> Void)? = nil,
    ) async throws -> OpenCsvWalletStore.PendingAccountOperation {
        let startedAt = Date()
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
        await progress?(.checkingWallet)
        let account = try await ensureAccountWallet()
        var status = try account.status()
        if !status.backupVerified {
            // Back up the root and empty/current checkpoint before Rust is
            // allowed to reserve any Bitcoin UTXO or prove an asset spend.
            try await backUpAccountCheckpoint(account: account)
            status = try account.status()
        }
        try Self.requireFeeReserve(status.feeReserve)

        let selection = try Self.resolveUsdSendAsset(
            status.assets,
            instruments: status.instruments,
            amount: amount,
            requestedAssetId: assetIdHex,
        )
        let asset = selection.credit
        let assetId = asset.assetId

        // Planning is deliberately cheap and durable. Rust starts a two-
        // second collection window but does not yet select protocol coins or
        // a Bitcoin input; the background prove step owns those decisions.
        let planned: OpenCsvAccountOperation
        do {
            planned = try account.planBatchedTransfer(
                assetId: assetId,
                toOwner: recipient,
                amount: amount,
            )
        } catch let error as OpenCsvClientError
            where error.ffiReason == "insufficient_fees"
        {
            throw OpenCsvPaymentsError.feeReserveRequired(
                minimumSats: Self.minimumFeeReserveSats,
                confirmedSats: status.feeReserve.confirmedSats,
            )
        }
        guard let batch = planned.batch else {
            throw OpenCsvClientError.decode("batched transfer plan omitted membership")
        }
        let pending = OpenCsvWalletStore.PendingAccountOperation(
            operationId: planned.operationId,
            threadUniqueId: threadUniqueId,
            amount: amount,
            currency: asset.currency,
            assetId: assetId,
            kind: "transfer",
            createdAt: Date(),
            batchLocalId: batch.batchLocalId,
            batchDeadlineMs: batch.deadlineMs,
            batchOrdinal: batch.ordinal,
        )
        do {
            try await db.awaitableWrite { tx in
                try self.store.upsertPendingAccountOperation(pending, tx: tx)
            }
        } catch {
            _ = try? account.cancelSendBatch(batch.batchLocalId)
            throw OpenCsvPaymentsError.couldNotPersistPendingSend(underlying: "\(error)")
        }
        requestBackgroundWorkScheduling()
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        Logger.info("durable OpenCSV send intent \(planned.operationId) saved in \(elapsedMs) ms")
        return pending
    }

    /// Add an already-selected recipient to an explicitly named collection
    /// window. A successful return is Rust's guarantee that this recipient
    /// will be in the same frozen Bitcoin transaction; expiry creates no
    /// fallback solo operation.
    public func addRecipientToQueuedBatch(
        batchLocalId: String,
        toOwnerHex: String,
        amount: UInt64,
        threadUniqueId: String,
        assetIdHex: String,
    ) async throws -> OpenCsvWalletStore.PendingAccountOperation {
        guard !isSending else {
            throw OpenCsvPaymentsError.sendAlreadyInProgress
        }
        let recipient = toOwnerHex.lowercased()
        guard recipient.count == 64, recipient.allSatisfy(\.isHexDigit) else {
            throw OpenCsvPaymentsError.malformedRecipient
        }
        isSending = true
        defer { isSending = false }
        let account = try await ensureAccountWallet()
        let status = try account.status()
        let selection = try Self.resolveUsdSendAsset(
            status.assets,
            instruments: status.instruments,
            amount: amount,
            requestedAssetId: assetIdHex,
        )
        let planned = try account.addBatchedRecipient(
            batchLocalId: batchLocalId,
            assetId: selection.credit.assetId,
            toOwner: recipient,
            amount: amount,
        )
        guard let batch = planned.batch, batch.batchLocalId == batchLocalId else {
            _ = try? account.cancelSendBatch(batchLocalId)
            throw OpenCsvClientError.decode("Add Recipient response omitted exact batch membership")
        }
        let pending = OpenCsvWalletStore.PendingAccountOperation(
            operationId: planned.operationId,
            threadUniqueId: threadUniqueId,
            amount: amount,
            currency: selection.credit.currency,
            assetId: selection.credit.assetId,
            kind: "transfer",
            createdAt: Date(),
            batchLocalId: batch.batchLocalId,
            batchDeadlineMs: batch.deadlineMs,
            batchOrdinal: batch.ordinal,
        )
        do {
            try await db.awaitableWrite { tx in
                try self.store.upsertPendingAccountOperation(pending, tx: tx)
            }
        } catch {
            _ = try? account.cancelSendBatch(batchLocalId)
            try? await db.awaitableWrite { tx in
                try self.store.removePendingAccountOperations(batchLocalId: batchLocalId, tx: tx)
            }
            throw OpenCsvPaymentsError.couldNotPersistPendingSend(underlying: "\(error)")
        }
        requestBackgroundWorkScheduling()
        return pending
    }

    /// Close membership immediately after the UI has durably added every
    /// preselected recipient. Automatic one-recipient sends instead let the
    /// full two-second coalescing window expire.
    @discardableResult
    public func freezeQueuedBatch(_ batchLocalId: String) async throws -> OpenCsvSendBatch {
        guard !isSending else {
            throw OpenCsvPaymentsError.sendAlreadyInProgress
        }
        isSending = true
        defer { isSending = false }
        let account = try await ensureAccountWallet()
        return try account.freezeSendBatch(batchLocalId)
    }

    /// Roll back the whole unsent manifest if explicit multi-recipient
    /// assembly cannot complete. Already-announced chat intents receive one
    /// terminal failure; invisible drafts are simply removed.
    public func cancelQueuedBatch(_ batchLocalId: String, reason: String) async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        guard let account = try? await ensureAccountWallet() else { return }
        guard (try? account.cancelSendBatch(batchLocalId)) != nil else { return }
        try? await db.awaitableWrite { tx in
            let operations = try self.store.pendingAccountOperations(tx: tx)
                .filter { $0.batchLocalId == batchLocalId }
            for operation in operations {
                if operation.announcementEnqueuedAt == nil {
                    try self.store.removePendingAccountOperation(operationId: operation.operationId, tx: tx)
                } else {
                    try self.store.markPendingAccountOperationFailed(
                        operationId: operation.operationId,
                        reason: reason,
                        tx: tx,
                    )
                }
            }
        }
    }

    /// Advance one queued transfer through proof, recovery protection,
    /// signing and broadcast. Callers may await it, but the send sheet does
    /// not: foreground and BGProcessing recovery both resume the same id.
    public func finishQueuedPayment(
        operationId: String,
        progress: (@MainActor @Sendable (OpenCsvSendProgress) -> Void)? = nil,
    ) async throws -> OpenCsvWalletStore.PendingDelivery {
        guard !isSending else {
            throw OpenCsvPaymentsError.sendAlreadyInProgress
        }
        guard
            let pending = try db.read(block: { tx in
                try self.store.pendingAccountOperations(tx: tx)
                    .first { $0.operationId == operationId }
            })
        else {
            throw OpenCsvClientError.ffi("queued OpenCSV operation is missing Signal metadata")
        }
        isSending = true
        defer { isSending = false }
        let account = try await ensureAccountWallet()
        if let batchLocalId = pending.batchLocalId {
            let deliveries = try await finishQueuedBatch(
                account: account,
                batchLocalId: batchLocalId,
                progress: progress,
            )
            guard let delivery = deliveries.first(where: { $0.operationId == operationId }) else {
                throw OpenCsvPaymentsError.consignmentNotReady(
                    operationId: operationId,
                    state: (try? account.sendBatchStatus(batchLocalId).state) ?? "unknown",
                )
            }
            return delivery
        }
        return try await finishQueuedSolo(account: account, pending: pending, progress: progress)
    }

    private func finishQueuedSolo(
        account: OpenCsvAccountWallet,
        pending: OpenCsvWalletStore.PendingAccountOperation,
        progress: (@MainActor @Sendable (OpenCsvSendProgress) -> Void)? = nil,
    ) async throws -> OpenCsvWalletStore.PendingDelivery {
        let operationId = pending.operationId
        var operation = try account.operationStatus(operationId)
        if operation.state == "planned" || operation.state == "fee_reserved" {
            await progress?(.generatingProof)
            let prepared = try await proveOperationWithCurrentChain(
                account: account,
                operationId: operationId,
            )
            return try await signPreparedOperation(
                account: account,
                operationId: prepared.operationId,
                expectedCheckpointHash: prepared.checkpointHash,
                pending: pending,
                progress: progress,
            )
        }
        if operation.state == "proof_ready" {
            let prepared = try account.proveOperation(operationId)
            return try await signPreparedOperation(
                account: account,
                operationId: prepared.operationId,
                expectedCheckpointHash: prepared.checkpointHash,
                pending: pending,
                progress: progress,
            )
        }
        if operation.state == "signed_persisted" || operation.state == "broadcast_unobserved" {
            await progress?(.broadcasting)
            operation = try account.resume(operationId)
        }
        if operation.state == "signed_persisted" || operation.state == "broadcast_unobserved" {
            operation = await observeSignedOperationIfAvailable(
                account: account,
                operation: operation,
            )
        }
        return try await persistDeliveryIfReady(operation: operation, pending: pending)
    }

    /// Advance one durable collection/frozen batch. The same method handles
    /// foreground completion and crash recovery; every boundary is an
    /// idempotent Rust journal state.
    private func finishQueuedBatch(
        account: OpenCsvAccountWallet,
        batchLocalId: String,
        progress: (@MainActor @Sendable (OpenCsvSendProgress) -> Void)? = nil,
    ) async throws -> [OpenCsvWalletStore.PendingDelivery] {
        let pending = try db.read { tx in
            try self.store.pendingAccountOperations(tx: tx)
                .filter { $0.batchLocalId == batchLocalId }
                .sorted { ($0.batchOrdinal ?? 0) < ($1.batchOrdinal ?? 0) }
        }
        guard !pending.isEmpty else {
            throw OpenCsvClientError.ffi("queued OpenCSV batch is missing Signal metadata")
        }
        var batch = try account.sendBatchStatus(batchLocalId)
        if batch.state == "collecting" {
            let remainingMs = max(0, batch.deadlineMs - Int64(Date().timeIntervalSince1970 * 1_000))
            if remainingMs > 0 {
                try await Task.sleep(nanoseconds: UInt64(remainingMs) * 1_000_000)
            }
            batch = try account.freezeSendBatch(batchLocalId)
        }
        if batch.state == "cancelled" {
            throw OpenCsvClientError.ffi("OpenCSV send batch was cancelled before broadcast")
        }
        if batch.state == "solo" {
            guard let only = pending.first else {
                throw OpenCsvClientError.ffi("solo OpenCSV batch has no Signal metadata")
            }
            return [try await finishQueuedSolo(account: account, pending: only, progress: progress)]
        }
        if batch.state == "frozen" {
            await progress?(.generatingProof)
            switch try await proveBatchWithCurrentChain(
                account: account,
                batchLocalId: batchLocalId,
            ) {
            case .solo(let operationId):
                guard let only = pending.first(where: { $0.operationId == operationId }) else {
                    throw OpenCsvClientError.ffi("solo OpenCSV operation lost Signal metadata")
                }
                return [try await finishQueuedSolo(account: account, pending: only, progress: progress)]
            case .batch(let prepared):
                batch = prepared
            }
        }
        if batch.state == "proof_ready", !batch.backupAcked {
            guard let checkpointHash = batch.checkpointHash else {
                throw OpenCsvClientError.decode("proof-ready batch omitted checkpoint hash")
            }
            await progress?(.protectingRecovery)
            try await backUpAccountCheckpoint(
                account: account,
                batchLocalId: batchLocalId,
                expectedCheckpointHash: checkpointHash,
            )
            batch = try account.sendBatchStatus(batchLocalId)
        }
        if batch.state == "proof_ready", batch.backupAcked {
            await progress?(.broadcasting)
            batch = try account.signAndBroadcastSendBatch(batchLocalId)
        } else if batch.state == "signed_persisted" || batch.state == "broadcast_unobserved" {
            await progress?(.broadcasting)
            batch = try account.resumeSendBatch(batchLocalId)
        }
        if batch.state == "signed_persisted" || batch.state == "broadcast_unobserved" {
            batch = await observeSignedBatchIfAvailable(account: account, batch: batch)
        }
        guard ["mempool", "confirmed"].contains(batch.state) else {
            throw OpenCsvPaymentsError.consignmentNotReady(
                operationId: pending[0].operationId,
                state: batch.state,
            )
        }

        var deliveries = [OpenCsvWalletStore.PendingDelivery]()
        let operationsById = Dictionary(uniqueKeysWithValues: batch.operations.map { ($0.operationId, $0) })
        for metadata in pending {
            guard let operation = operationsById[metadata.operationId] else {
                throw OpenCsvClientError.decode("batch receipt omitted operation \(metadata.operationId)")
            }
            deliveries.append(try await persistDeliveryIfReady(operation: operation, pending: metadata))
        }
        return deliveries
    }

    /// Cached balances keep the send UI instant, but proof generation cannot
    /// race the independently verified nullifier scan. A failed sync leaves
    /// the Rust operation and fee reservation untouched for the next
    /// foreground/BGProcessing retry.
    private func requireChainVerificationForProof() async throws {
        if scanSyncedThisLaunch {
            return
        }
        guard await scanSyncIfNeeded() else {
            Logger.info("OpenCSV proof remains queued while chain verification catches up")
            throw OpenCsvPaymentsError.chainVerificationUnavailable
        }
    }

    /// Rust independently verifies the selected fee input immediately before
    /// proving. Its funding view can advance by one block after the phone's
    /// scan completed but before this call begins. That is a freshness race,
    /// not a terminal operation result: invalidate the cached launch receipt,
    /// advance the phone-owned scan, and retry the same durable operation id.
    /// The retry count is bounded so unavailable peers never become a busy
    /// loop, while a block arriving during the first refresh still converges.
    private func proveOperationWithCurrentChain(
        account: OpenCsvAccountWallet,
        operationId: String,
    ) async throws -> OpenCsvPreparedOperation {
        for retry in 0...2 {
            try await requireChainVerificationForProof()
            do {
                return try account.proveOperation(operationId)
            } catch {
                guard Self.isChainVerificationUnavailable(error), retry < 2 else {
                    throw error
                }
                scanSyncedThisLaunch = false
                Logger.info("funding view advanced; refreshing phone-owned scan before proof retry")
            }
        }
        throw OpenCsvPaymentsError.chainVerificationUnavailable
    }

    private func proveBatchWithCurrentChain(
        account: OpenCsvAccountWallet,
        batchLocalId: String,
    ) async throws -> OpenCsvSendBatchProofResult {
        for retry in 0...2 {
            try await requireChainVerificationForProof()
            do {
                return try account.proveSendBatch(batchLocalId)
            } catch {
                guard Self.isChainVerificationUnavailable(error), retry < 2 else {
                    throw error
                }
                scanSyncedThisLaunch = false
                Logger.info("funding view advanced; refreshing phone-owned scan before batch proof retry")
            }
        }
        throw OpenCsvPaymentsError.chainVerificationUnavailable
    }

    /// Match only Rust's stable reason prefix. Human-readable detail is not
    /// an API and must never turn a definitive protocol rejection retryable.
    static func isChainVerificationUnavailable(_ error: Error) -> Bool {
        guard let clientError = error as? OpenCsvClientError else { return false }
        if clientError.ffiReason == "chain_verification_unavailable" {
            return true
        }
        guard case .ffi(let message) = clientError else { return false }
        return message == "chain_verification_unavailable"
            || message.hasPrefix("chain_verification_unavailable:")
    }

    /// A previously admitted zero-confirmation payment becomes nonspendable
    /// only on Rust's stable dependency-conflict reasons. Human-readable
    /// error text must never decide whether Signal freezes a payment.
    static func isUnconfirmedParentFailure(_ error: Error) -> Bool {
        guard
            let clientError = error as? OpenCsvClientError,
            let reason = clientError.ffiReason
        else { return false }
        return [
            "unconfirmed_anchor_missing",
            "unconfirmed_anchor_mismatch",
            "observer_transaction_conflict",
        ].contains(reason)
    }

    /// Compatibility call for tests and non-interactive clients that still
    /// want one awaitable prove→broadcast result.
    public func sendPayment(
        toOwnerHex: String,
        amount: UInt64,
        threadUniqueId: String,
        assetIdHex: String? = nil,
        progress: (@MainActor @Sendable (OpenCsvSendProgress) -> Void)? = nil,
    ) async throws -> OpenCsvWalletStore.PendingDelivery {
        let queued = try await queuePayment(
            toOwnerHex: toOwnerHex,
            amount: amount,
            threadUniqueId: threadUniqueId,
            assetIdHex: assetIdHex,
            progress: progress,
        )
        return try await finishQueuedPayment(operationId: queued.operationId, progress: progress)
    }

    /// Resolve Signal's one USD product to one exact trusted issuer claim.
    /// Priority is deterministic, but a send never combines issuers. A
    /// caller-supplied id is accepted only if it remains in the reviewed
    /// configuration and can cover the entire amount.
    public nonisolated static func resolveUsdSendAsset(
        _ assets: [OpenCsvCredit],
        instruments: [OpenCsvInstrumentRecord],
        amount: UInt64,
        requestedAssetId: String?,
    ) throws -> OpenCsvUsdSendSelection {
        let trusted = instruments.filter {
            $0.profile == "trusted_test_usd_v2"
                && $0.trustState == "trusted_configuration"
                && $0.manifest?.terms.unitCode == "USD"
                && $0.manifest?.terms.decimals == 6
        }.sorted {
            let left = ($0.issuerPriority ?? UInt32.max, $0.assetId)
            let right = ($1.issuerPriority ?? UInt32.max, $1.assetId)
            return left < right
        }
        let trustedIds = Set(trusted.map(\.assetId))
        var balances = [String: OpenCsvCredit]()
        for credit in assets where trustedIds.contains(credit.assetId) {
            guard let existing = balances[credit.assetId] else {
                balances[credit.assetId] = credit
                continue
            }
            let (combined, overflow) = existing.amount.addingReportingOverflow(credit.amount)
            balances[credit.assetId] = OpenCsvCredit(
                assetId: credit.assetId,
                currency: existing.currency ?? credit.currency,
                amount: overflow ? UInt64.max : combined,
            )
        }

        if let requestedAssetId {
            guard
                let instrument = trusted.first(where: { $0.assetId == requestedAssetId }),
                let credit = balances[requestedAssetId]
            else {
                throw OpenCsvPaymentsError.insufficientFunds(available: 0)
            }
            guard credit.amount >= amount else {
                throw OpenCsvPaymentsError.insufficientFunds(available: credit.amount)
            }
            return OpenCsvUsdSendSelection(credit: credit, instrument: instrument)
        }

        for instrument in trusted {
            if let credit = balances[instrument.assetId], credit.amount >= amount {
                return OpenCsvUsdSendSelection(credit: credit, instrument: instrument)
            }
        }

        let total = balances.values.reduce(UInt64(0)) { partial, credit in
            let (combined, overflow) = partial.addingReportingOverflow(credit.amount)
            return overflow ? UInt64.max : combined
        }
        if total >= amount, trusted.count > 1 {
            throw OpenCsvPaymentsError.issuerSplitRequired(totalAvailable: total)
        }
        throw OpenCsvPaymentsError.insufficientFunds(available: total)
    }

    /// Whether the public account status has an output that can satisfy the
    /// first funding-input policy. Rust rechecks this at reservation time.
    public nonisolated static func hasConfirmedUnreservedFeeUtxo(
        _ reserve: OpenCsvAccountStatus.FeeReserve,
    ) -> Bool {
        guard reserve.confirmedSats >= minimumFeeReserveSats else { return false }
        return reserve.utxos.contains {
            !$0.reserved && $0.valueSats >= minimumFeeReserveSats
        }
    }

    private nonisolated static func requireFeeReserve(
        _ reserve: OpenCsvAccountStatus.FeeReserve,
    ) throws {
        guard hasConfirmedUnreservedFeeUtxo(reserve) else {
            throw OpenCsvPaymentsError.feeReserveRequired(
                minimumSats: minimumFeeReserveSats,
                confirmedSats: reserve.confirmedSats,
            )
        }
    }

    /// Replace an unconfirmed OpenCSV anchor with a protocol-safe RBF
    /// transaction. There is intentionally no equivalent API accepting a
    /// Bitcoin recipient, PSBT, raw transaction, or caller-selected UTXO.
    public func feeBump(
        operationId: String,
        targetSatPerVb: UInt64,
    ) async throws -> OpenCsvAccountOperation {
        guard !isSending else {
            throw OpenCsvPaymentsError.sendAlreadyInProgress
        }
        guard targetSatPerVb > 0 else {
            throw OpenCsvClientError.ffi("fee rate must be positive")
        }
        isSending = true
        defer { isSending = false }
        let account = try await ensureAccountWallet()
        if try !account.status().backupVerified {
            try await backUpAccountCheckpoint(account: account)
        }
        guard
            try account.operationSummaries().contains(where: {
                $0.operationId == operationId
                    && ["broadcast_unobserved", "broadcast", "mempool"].contains($0.state)
            })
        else {
            throw OpenCsvClientError.ffi("operation is not an unconfirmed OpenCSV transaction")
        }
        var replacement = try account.feeBump(
            operationId: operationId,
            targetSatPerVb: targetSatPerVb,
        )
        do {
            // Capture the replacement txid/journal after Rust has persisted
            // it. A failure here never makes the committed RBF safe to retry.
            try await backUpAccountCheckpoint(account: account)
        } catch {
            Logger.error("OpenCSV fee bump committed but backup refresh failed: \(error)")
            throw OpenCsvPaymentsError.feeBumpCommittedBackupPending(
                operationId: operationId,
                txid: replacement.txid,
            )
        }
        replacement = await observeSignedOperationIfAvailable(
            account: account,
            operation: replacement,
        )
        if replacement.state == "mempool" {
            do {
                try await backUpAccountCheckpoint(account: account)
            } catch {
                throw OpenCsvPaymentsError.feeBumpCommittedBackupPending(
                    operationId: operationId,
                    txid: replacement.txid,
                )
            }
        }
        return replacement
    }

    private func signPreparedOperation(
        account: OpenCsvAccountWallet,
        operationId: String,
        expectedCheckpointHash: String,
        pending: OpenCsvWalletStore.PendingAccountOperation,
        progress: (@MainActor @Sendable (OpenCsvSendProgress) -> Void)?,
    ) async throws -> OpenCsvWalletStore.PendingDelivery {
        await progress?(.protectingRecovery)
        try await backUpAccountCheckpoint(
            account: account,
            operationId: operationId,
            expectedCheckpointHash: expectedCheckpointHash,
        )
        do {
            await progress?(.broadcasting)
            var operation = try account.signAndBroadcast(
                operationId: operationId,
                targetSatPerVb: 2,
            )
            operation = await observeSignedOperationIfAvailable(
                account: account,
                operation: operation,
            )
            return try await persistDeliveryIfReady(operation: operation, pending: pending)
        } catch {
            if
                let operation = try? account.operationStatus(operationId),
                operation.state == "signed_persisted"
                || operation.state == "broadcast_unobserved"
                || operation.state == "broadcast"
            {
                throw OpenCsvPaymentsError.consignmentNotReady(
                    operationId: operationId,
                    state: operation.state,
                )
            }
            throw error
        }
    }

    private func observeSignedOperationIfAvailable(
        account: OpenCsvAccountWallet,
        operation: OpenCsvAccountOperation,
    ) async -> OpenCsvAccountOperation {
        guard let txid = operation.txid else { return operation }
        do {
            let status = try account.status()
            if status.network == "signet" {
                let policy = status.observationPolicy
                    ?? db.read { self.store.observationChecks(tx: $0) }
                let observationSet = try await OpenCsvPinnedObserver.observeSignetTransaction(
                    txid: txid,
                    policy: policy,
                )
                return try account.observeUnconfirmedOperation(
                    operation.operationId,
                    rawTransaction: observationSet.rawTransaction,
                    observations: observationSet.evidence,
                )
            }
            // Regtest acceptance uses the explicitly configured local
            // accelerator. Mainnet remains unavailable in this development
            // build and is never silently routed through this path.
            if status.network == "regtest" {
                return try account.operationStatus(operation.operationId)
            }
        } catch {
            Logger.warn("OpenCSV signed transaction remains pending independent observation: \(error)")
        }
        return operation
    }

    private func observeSignedBatchIfAvailable(
        account: OpenCsvAccountWallet,
        batch: OpenCsvSendBatch,
    ) async -> OpenCsvSendBatch {
        guard let txid = batch.txid else { return batch }
        do {
            let status = try account.status()
            if status.network == "signet" {
                let policy = status.observationPolicy
                    ?? db.read { self.store.observationChecks(tx: $0) }
                let observationSet = try await OpenCsvPinnedObserver.observeSignetTransaction(
                    txid: txid,
                    policy: policy,
                )
                return try account.observeUnconfirmedSendBatch(
                    batch.batchLocalId,
                    rawTransaction: observationSet.rawTransaction,
                    observations: observationSet.evidence,
                )
            }
            if status.network == "regtest" {
                return try account.sendBatchStatus(batch.batchLocalId)
            }
        } catch {
            Logger.warn("OpenCSV shared transaction remains pending independent observation: \(error)")
        }
        return batch
    }

    private func persistDeliveryIfReady(
        operation: OpenCsvAccountOperation,
        pending: OpenCsvWalletStore.PendingAccountOperation,
    ) async throws -> OpenCsvWalletStore.PendingDelivery {
        guard
            let receipt = operation.receipt,
            receipt.deliveryReady == true,
            let encoded = receipt.consignmentBase64,
            let consignmentId = receipt.consignmentId,
            let blob = Data(base64Encoded: encoded)
        else {
            throw OpenCsvPaymentsError.consignmentNotReady(
                operationId: operation.operationId,
                state: operation.state,
            )
        }
        if
            let existing = db.read(block: { tx in
                Self.pendingDelivery(
                    operationId: operation.operationId,
                    consignmentId: consignmentId,
                    in: self.store.pendingDeliveries(tx: tx),
                )
            })
        {
            return existing
        }
        let account = try await ensureAccountWallet()
        let inspection = try account.inspect(blob: blob)
        guard inspection.consignmentId == consignmentId else {
            throw OpenCsvClientError.decode("operation receipt and canonical consignment disagree")
        }
        let owner = try account.status().owners.first
        var body = OpenCsvAttachmentDetector.outgoingBody(byteCount: blob.count)
        body += "\nOpenCSV payment: \(operation.operationId)"
        if let owner {
            body += "\n" + OpenCsvAttachmentDetector.addressAnnouncement(owner: owner)
        }
        return try await db.awaitableWrite { tx in
            // Recheck inside the serial database transaction. The actor may
            // re-enter while fetching account status above, and a concurrent
            // recovery pass may have persisted this exact operation meanwhile.
            if
                let existing = Self.pendingDelivery(
                    operationId: operation.operationId,
                    consignmentId: consignmentId,
                    in: self.store.pendingDeliveries(tx: tx),
                )
            {
                return existing
            }
            // Keep one encrypted replay copy for the existing attachment
            // transport and explorer. Rust remains the source of truth for
            // spends and operation state.
            let entry = try self.store.recordOutgoing(blob: blob, spends: [], tx: tx)
            let delivery = OpenCsvWalletStore.PendingDelivery(
                id: "operation:\(operation.operationId):\(consignmentId)",
                threadUniqueId: pending.threadUniqueId,
                body: body,
                replayEntry: entry,
                amount: pending.amount,
                currency: pending.currency,
                assetId: pending.assetId,
                operationKind: pending.kind,
                operationId: operation.operationId,
                deliveryNonce: operation.deliveryNonce,
                consignmentId: consignmentId,
                paymentId: inspection.paymentId,
                supersededConsignmentIds: receipt.supersededConsignmentIds,
                replacesTxid: receipt.replaces,
                createdAt: pending.createdAt,
            )
            try self.store.addPendingDelivery(delivery, tx: tx)
            return delivery
        }
    }

    /// A protocol-safe fee replacement keeps the logical operation id but
    /// rotates its txid-bound canonical consignment. Deduplicate only the
    /// exact pair so crash recovery can enqueue the replacement attachment.
    nonisolated static func pendingDelivery(
        operationId: String,
        consignmentId: String,
        in deliveries: [OpenCsvWalletStore.PendingDelivery],
    ) -> OpenCsvWalletStore.PendingDelivery? {
        deliveries.first {
            $0.operationId == operationId && $0.consignmentId == consignmentId
        }
    }

    /// Resume Rust-durable operations and migrate any prototype-era sends.
    public func recoverInterruptedSends() async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        if let account = try? await ensureAccountWallet() {
            // Never put fee-cell inventory maintenance in front of a durable
            // user operation. Resuming an unobserved maintenance transaction
            // can wait on the network; serializing that wait here leaves a
            // freshly announced payment stuck at `planned`. Explicit wallet
            // sync owns reserve maintenance and may retry it independently.
            let operations = ((try? db.read { try self.store.pendingAccountOperations(tx: $0) }) ?? [])
                .filter { $0.failureReason == nil }
            if !operations.isEmpty {
                Logger.info("resuming \(operations.count) durable OpenCSV operation(s)")
            }
            let groupedBatches = Dictionary(
                grouping: operations.compactMap { operation in
                    operation.batchLocalId.map { ($0, operation) }
                },
                by: \.0,
            )
            for (batchLocalId, entries) in groupedBatches {
                let pending = entries.map(\.1).sorted { ($0.batchOrdinal ?? 0) < ($1.batchOrdinal ?? 0) }
                // Every recipient sees its authenticated intent before any
                // member can release a signature. The delivery pass that
                // called us inserts all missing announcements first.
                guard pending.allSatisfy({ $0.announcementEnqueuedAt != nil }) else { continue }
                do {
                    _ = try await finishQueuedBatch(
                        account: account,
                        batchLocalId: batchLocalId,
                    )
                } catch OpenCsvPaymentsError.consignmentNotReady {
                    Logger.info("OpenCSV batch \(batchLocalId) is durable and awaiting observation")
                } catch {
                    let terminalBatch = try? account.sendBatchStatus(batchLocalId)
                    if terminalBatch?.state == "cancelled" {
                        let rejectionByOperation = Dictionary(
                            uniqueKeysWithValues: terminalBatch?.operations.compactMap { operation in
                                operation.rejectionReason.map { (operation.operationId, $0) }
                            } ?? [],
                        )
                        try? await db.awaitableWrite { tx in
                            for operation in pending {
                                try self.store.markPendingAccountOperationFailed(
                                    operationId: operation.operationId,
                                    reason: rejectionByOperation[operation.operationId]
                                        ?? "batch_cancelled",
                                    tx: tx,
                                )
                            }
                        }
                    }
                    Logger.warn("could not resume OpenCSV batch \(batchLocalId): \(error)")
                }
            }

            // Records written before durable coalescing remain on the exact
            // established solo recovery path.
            for pending in operations where pending.batchLocalId == nil {
                do {
                    var operation = try account.operationStatus(pending.operationId)
                    if operation.state == "planned" || operation.state == "fee_reserved" {
                        // Never spend for an intent that Signal could not
                        // first enqueue into its conversation. Older
                        // proof-ready/broadcast records remain recoverable.
                        guard pending.announcementEnqueuedAt != nil else { continue }
                        // Proof generation is deliberately background work.
                        // The exact intent and chat metadata were durable
                        // before this point, so app termination merely causes
                        // the same operation id to re-enter here.
                        _ = try await proveOperationWithCurrentChain(
                            account: account,
                            operationId: pending.operationId,
                        )
                        operation = try account.operationStatus(pending.operationId)
                    }
                    if
                        operation.state == "proof_ready", !operation.backupAcked,
                        let checkpointHash = operation.checkpointHash
                    {
                        try await backUpAccountCheckpoint(
                            account: account,
                            operationId: operation.operationId,
                            expectedCheckpointHash: checkpointHash,
                        )
                        operation = try account.operationStatus(pending.operationId)
                    }
                    if operation.state == "proof_ready", operation.backupAcked {
                        operation = try account.signAndBroadcast(
                            operationId: pending.operationId,
                            targetSatPerVb: 2,
                        )
                    } else if
                        operation.state == "signed_persisted"
                        || operation.state == "broadcast_unobserved"
                    {
                        operation = try account.resume(pending.operationId)
                    }
                    if
                        operation.state == "cancelled"
                        || operation.state == "rejected"
                        || operation.state == "protocol_rejected"
                    {
                        try await db.awaitableWrite { tx in
                            try self.store.markPendingAccountOperationFailed(
                                operationId: pending.operationId,
                                reason: operation.rejectionReason ?? operation.state,
                                tx: tx,
                            )
                        }
                    } else if operation.state == "consignment_delivered" {
                        try await finishDeliveryAcknowledgement(
                            operationId: pending.operationId,
                            deliveryNonce: operation.deliveryNonce,
                            removeOperationMetadata: true,
                        )
                    } else if operation.receipt?.consignmentDelivered == true {
                        // The current exact-txid consignment was delivered,
                        // but its mempool transaction remains fee-bumpable.
                        // Retain chat metadata so an RBF replacement can
                        // generate and deliver fresh canonical bytes.
                        continue
                    } else {
                        _ = try await persistDeliveryIfReady(operation: operation, pending: pending)
                    }
                } catch OpenCsvPaymentsError.consignmentNotReady {
                    Logger.info("OpenCSV operation \(pending.operationId) is durable and awaiting observation")
                } catch {
                    if
                        let terminal = try? account.operationStatus(pending.operationId),
                        ["cancelled", "rejected", "protocol_rejected"].contains(terminal.state)
                    {
                        try? await db.awaitableWrite { tx in
                            try self.store.markPendingAccountOperationFailed(
                                operationId: pending.operationId,
                                reason: terminal.rejectionReason ?? "\(error)",
                                tx: tx,
                            )
                        }
                        Logger.warn("OpenCSV operation \(pending.operationId) failed: \(error)")
                    } else {
                        Logger.warn("could not resume OpenCSV operation \(pending.operationId): \(error)")
                    }
                }
            }
            await reconcileCommittedDeliveries(account: account)
        }

        // Retain recovery for already-persisted prototype sends. New sends
        // never create these records or call a bespoke anchor server.
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
            // The Signal message already exists. Foreground reconciliation
            // will finish Rust's idempotent acknowledgement; never enqueue a
            // second copy of the same payment attachment.
            if delivery.enqueuedAt != nil { return false }
            if deliveriesInFlight.contains(delivery.id) { return false }
            if delivery.hasExhaustedRetries {
                Logger.warn("OpenCSV delivery \(delivery.id) exhausted retries; leaving it queued")
                return false
            }
            return true
        }
    }

    /// Durable operations that do not yet have their fast, explicitly
    /// nonspendable Signal intent message. The delivery layer inserts that
    /// message and updates this metadata in one database transaction.
    public func operationsNeedingAnnouncement() -> [OpenCsvWalletStore.PendingAccountOperation] {
        let operations = (try? db.read { try self.store.pendingAccountOperations(tx: $0) }) ?? []
        return operations.filter {
            $0.announcementEnqueuedAt == nil && $0.failureReason == nil
        }
    }

    public func failedOperationsNeedingAnnouncement() -> [OpenCsvWalletStore.PendingAccountOperation] {
        let operations = (try? db.read { try self.store.pendingAccountOperations(tx: $0) }) ?? []
        return operations.filter { $0.failureReason != nil }
    }

    public nonisolated func markOperationAnnounced(
        operationId: String,
        messageId: String,
        tx: DBWriteTransaction,
    ) throws {
        try OpenCsvWalletStore(
            keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage,
        ).markPendingAccountOperationAnnounced(
            operationId: operationId,
            messageId: messageId,
            tx: tx,
        )
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
        messageUniqueId: String?,
        tx: DBWriteTransaction,
    ) {
        OpenCsvWalletStore(keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage)
            .setVerdict(
                record,
                blob: nil,
                attachmentId: attachmentId,
                messageUniqueId: messageUniqueId,
                tx: tx,
            )
    }

    /// Mark a delivery enqueued inside the message-insertion transaction.
    /// Account-era records remain until Rust acknowledges operation+nonce;
    /// legacy records can be removed immediately.
    public nonisolated func clearDelivered(id: String, tx: DBWriteTransaction) throws {
        let store = OpenCsvWalletStore(
            keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage,
        )
        guard let delivery = store.pendingDeliveries(tx: tx).first(where: { $0.id == id }) else {
            return
        }
        if delivery.operationId == nil {
            try store.removePendingDelivery(id: id, tx: tx)
        } else {
            try store.markPendingDeliveryEnqueued(id: id, tx: tx)
        }
    }

    /// Complete Rust's idempotent delivery acknowledgement after the Signal
    /// transaction commits. If the app dies first, foreground recovery sees
    /// `enqueuedAt` and performs this exact step without re-sending.
    public func acknowledgeDelivered(_ delivery: OpenCsvWalletStore.PendingDelivery) async {
        guard let operationId = delivery.operationId, let nonce = delivery.deliveryNonce else {
            return
        }
        do {
            let account = try await ensureAccountWallet()
            let acknowledged = try account.markDelivered(operationId: operationId, deliveryNonce: nonce)
            try await finishDeliveryAcknowledgement(
                operationId: operationId,
                deliveryNonce: nonce,
                removeOperationMetadata: acknowledged.state == "consignment_delivered",
            )
        } catch {
            Logger.warn("could not acknowledge OpenCSV delivery \(delivery.id) yet: \(error)")
        }
    }

    private func reconcileCommittedDeliveries(account: OpenCsvAccountWallet) async {
        let deliveries = db.read { self.store.pendingDeliveries(tx: $0) }
            .filter { $0.enqueuedAt != nil && $0.operationId != nil && $0.deliveryNonce != nil }
        for delivery in deliveries {
            do {
                let acknowledged = try account.markDelivered(
                    operationId: delivery.operationId!,
                    deliveryNonce: delivery.deliveryNonce!,
                )
                try await finishDeliveryAcknowledgement(
                    operationId: delivery.operationId!,
                    deliveryNonce: delivery.deliveryNonce!,
                    removeOperationMetadata: acknowledged.state == "consignment_delivered",
                )
            } catch {
                Logger.warn("OpenCSV delivery acknowledgement remains retryable: \(error)")
            }
        }
    }

    private func finishDeliveryAcknowledgement(
        operationId: String,
        deliveryNonce: String,
        removeOperationMetadata: Bool,
    ) async throws {
        try await db.awaitableWrite { tx in
            try self.store.removeAcknowledgedPendingDelivery(
                operationId: operationId,
                deliveryNonce: deliveryNonce,
                tx: tx,
            )
            if removeOperationMetadata {
                try self.store.removePendingAccountOperation(operationId: operationId, tx: tx)
            }
        }
    }

    /// The verdict to write for a consignment we sent, in the same
    /// transaction that inserts its message.
    public nonisolated func outgoingVerdict(
        for delivery: OpenCsvWalletStore.PendingDelivery,
    ) -> OpenCsvVerdictRecord {
        if delivery.operationKind == "mint" {
            return OpenCsvVerdictRecord(
                mintedAmount: delivery.amount,
                currency: delivery.currency,
                assetId: delivery.assetId,
                consignmentId: delivery.consignmentId,
                paymentId: delivery.paymentId,
                supersededConsignmentIds: delivery.supersededConsignmentIds,
                date: Date(),
            )
        }
        return OpenCsvVerdictRecord(
            sentAmount: delivery.amount,
            currency: delivery.currency,
            assetId: delivery.assetId,
            consignmentId: delivery.consignmentId,
            paymentId: delivery.paymentId,
            supersededConsignmentIds: delivery.supersededConsignmentIds,
            date: Date(),
        )
    }

    // MARK: - Settings / status

    public func walletSummary() async throws -> WalletSummary {
        let account = try await ensureAccountWallet()
        let status = try account.status()
        let observationPolicy = status.observationPolicy
            ?? db.read { store.observationChecks(tx: $0) }
        let requiredRawObserverQuorum = status.requiredRawObserverQuorum
            ?? UInt32(clamping: observationPolicy.filter {
                $0.kind == .rawTransactionApi && $0.mode == .require
            }.count)
        let summary = WalletSummary(
            cachedAt: Date(),
            owner: status.owners.first ?? "",
            balances: status.assets,
            incomingActivities: db.read { self.store.incomingActivities(tx: $0) },
            instruments: status.instruments,
            operations: try account.operationSummaries(),
            feeReserve: status.feeReserve,
            batchReserves: status.batchReserves,
            bitcoinDepositAddress: status.depositAddress,
            backupVerified: status.backupVerified,
            writeEnabled: status.writeEnabled,
            accountRole: status.role,
            deviceBindingStatus: status.deviceBinding.status,
            syncProvenance: status.syncProvenance,
            verifiedChainView: db.read { store.verifiedChainView(tx: $0) },
            esploraUrl: db.read { URL(string: store.esploraUrl(tx: $0)) },
            spvPeers: db.read { tx in
                Self.effectiveSpvPeers(
                    configured: store.spvPeers(tx: tx),
                    network: status.network,
                )
            },
            scanFromHeight: db.read { store.scanFromHeight(tx: $0) },
            network: status.network,
            deploymentId: status.deploymentId,
            observationPolicy: observationPolicy,
            requiredRawObserverQuorum: requiredRawObserverQuorum,
            observationReceipts: status.observationReceipts ?? [],
        )
        do {
            let encoded = try JSONEncoder().encode(summary)
            await db.awaitableWrite { tx in
                self.store.setWalletPresentationSnapshotData(encoded, tx: tx)
            }
        } catch {
            Logger.warn("could not persist OpenCSV wallet presentation snapshot: \(error)")
        }
        return summary
    }

    /// Read-only presentation cached outside this actor. A blocking wallet
    /// sync therefore cannot hide a previously known balance or activity.
    /// All writes still reopen Rust-owned state and re-run mandatory policy.
    public nonisolated func cachedWalletSummary() -> WalletSummary? {
        let store = OpenCsvWalletStore(
            keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage,
        )
        return DependenciesBridge.shared.db.read { tx in
            guard let data = store.walletPresentationSnapshotData(tx: tx) else { return nil }
            do {
                return try JSONDecoder().decode(WalletSummary.self, from: data)
            } catch {
                Logger.warn("ignoring invalid OpenCSV wallet presentation snapshot: \(error)")
                return nil
            }
        }
    }

    public func setEsploraUrl(_ urlString: String?) async {
        await db.awaitableWrite { tx in
            self.store.setEsploraUrl(urlString, tx: tx)
        }
        accountWallet = nil
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
        accountWallet = nil
    }

    public func setObservationMode(
        _ mode: OpenCsvObservationMode,
        checkId: String,
    ) async throws {
        let changed = try await db.awaitableWrite { tx in
            try self.store.setObservationMode(mode, checkId: checkId, tx: tx)
        }
        guard changed else {
            throw OpenCsvClientError.ffi("unknown observation check: \(checkId)")
        }
        // Rust owns enforcement. Reopen the account so the next verification
        // uses the newly persisted policy rather than a stale process handle.
        accountWallet = nil
    }

    /// Set the birth height for a fresh phone-owned scan. Existing scan
    /// indexes only ever resume, so this setting cannot silently discard or
    /// truncate already-verified history.
    public func setScanFromHeight(_ height: UInt64) async {
        do {
            try await db.awaitableWrite { tx in
                try self.store.setScanFromHeight(max(1, height), tx: tx)
            }
        } catch {
            Logger.error("could not persist OpenCSV scan birth height: \(error)")
        }
        scanSyncedThisLaunch = false
        closeCbfClient()
    }

    public func setNetwork(_ network: String) async throws {
        let requested = network.lowercased()
        guard ["mainnet", "signet", "regtest"].contains(requested) else {
            throw OpenCsvPaymentsError.unsupportedNetwork(network)
        }
        guard Self.isConsumerProductConfigured(for: requested) else {
            throw OpenCsvPaymentsError.productionUsdNotConfigured
        }
        let current = db.read { self.store.network(tx: $0) }
        guard requested != current else { return }
        guard !Self.hasPersistedAccountDatabase() else {
            throw OpenCsvPaymentsError.networkChangeRequiresIsolatedWallet(
                current: current,
                requested: requested,
            )
        }
        await db.awaitableWrite { tx in
            self.store.setNetwork(requested, tx: tx)
        }
        // The scan index and header cache are per-network; a change makes
        // any synced state meaningless until the next sync, and the
        // persistent client's connections point at the wrong chain.
        scanSyncedThisLaunch = false
        closeCbfClient()
        accountWallet = nil
    }

    /// Network selection is permitted only before a durable account exists.
    /// Regtest resets and signet/mainnet transitions use an isolated install;
    /// account databases and their sibling `.cbf` caches are never deleted or
    /// silently repurposed by a settings edit.
    private static func hasPersistedAccountDatabase() -> Bool {
        let directory = accountDatabaseDirectory(
            base: OWSFileSystem.appSharedDataDirectoryURL(),
        )
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
            )
        else {
            return false
        }
        return entries.contains { url in
            url.lastPathComponent == "account-v2.sqlite"
                || (
                    url.lastPathComponent.hasPrefix("linked-account-v2-")
                        && url.pathExtension == "sqlite"
                )
        }
    }

    static func accountDatabaseDirectory(base: URL) -> URL {
        base.appendingPathComponent("opencsv", isDirectory: true)
    }

    /// The consumer wallet may enter mainnet only when this build carries a
    /// reviewed production issuer. Regtest remains available to developers;
    /// signet remains the permanent home of Test USD.
    static func isConsumerProductConfigured(for network: String) -> Bool {
        guard network == "mainnet" else { return true }
        return OpenCsvReviewedUsdIssuers.policies(for: network).contains { policy in
            policy.manifest.terms.unitCode == "USD"
                && !policy.manifest.terms.testOnly
        }
    }

    /// A stored verdict, for the conversation cell (main-thread render path).
    public nonisolated func verdict(attachmentId: Attachment.IDType, tx: DBReadTransaction) -> OpenCsvVerdictRecord? {
        OpenCsvWalletStore(keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage)
            .verdict(attachmentId: attachmentId, tx: tx)
    }

    public nonisolated func isCanonicalPresentationAttachment(
        attachmentId: Attachment.IDType,
        messageUniqueId: String?,
        tx: DBReadTransaction,
    ) -> Bool {
        OpenCsvWalletStore(keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage)
            .isCanonicalPresentationAttachment(
                attachmentId: attachmentId,
                messageUniqueId: messageUniqueId,
                tx: tx,
            )
    }

    public nonisolated func hasCanonicalPresentation(
        consignmentId: String,
        tx: DBReadTransaction,
    ) -> Bool {
        OpenCsvWalletStore(keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage)
            .hasCanonicalPresentation(consignmentId: consignmentId, tx: tx)
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
        var txid: String? = record?.anchorTxid
        var recordHex: String?
        var ctx: String?
        var confirmations: UInt64?
        var tip: UInt64?
        if let blob, let wallet = try? await ensureWallet() {
            if !scanSyncedThisLaunch {
                await scanSyncIfNeeded()
            }
            if
                let snapshot = try? OpenCsvChainView.exportScanSnapshot(),
                let verdict = try? wallet.verify(
                    blob: blob,
                    snapshotJson: snapshot,
                    requiredConfirmations: 0,
                ),
                let liveAnchor = verdict.anchor
            {
                anchor = liveAnchor
                if
                    let entry = OpenCsvChainView.snapshotEntryDetails(
                        fromSnapshotJson: snapshot,
                        anchor: liveAnchor,
                    )
                {
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
            anchorHeight: anchor?.height ?? (record?.finality == "unconfirmed" ? 0 : nil),
            anchorPosition: anchor?.position ?? (record?.finality == "unconfirmed" ? 0 : nil),
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
        guard
            let blob = db.read(block: { tx in
                self.store.blobForAttachment(attachmentId: attachmentId, tx: tx)
            })
        else {
            throw OpenCsvPaymentsError.consignmentSizeRejected(bytes: 0)
        }
        let wallet = try await ensureWallet()
        await scanSyncIfNeeded()
        let scanned = try OpenCsvChainView.scanVerify(wallet: wallet, consignment: blob)
        return scanned.isVerified
    }

    // MARK: - Wallet lifecycle

    private static let defaultSignetPeers = [
        // Qualified against the public signet DNS seed with the OpenCSV
        // headers+BIP158 readiness probe. Ordinary reachable signet nodes
        // are not enough: each default must advertise compact filters and
        // complete an independently validated header/filter-header sync.
        "176.9.8.81:38333",
        "180.189.55.15:38333",
        "185.209.178.165:38333",
    ]

    /// Signet ships with the same reviewed phone-owned chain view used for
    /// Bitcoin writes. An empty settings row means "use the reviewed
    /// defaults", not "silently downgrade receive verification to one
    /// public indexer". Explicit configuration always replaces defaults;
    /// production networks never acquire peers implicitly.
    static func effectiveSpvPeers(configured: [String], network: String) -> [String] {
        if configured.isEmpty, network == "signet" {
            return defaultSignetPeers
        }
        return configured
    }

    /// Open the durable Rust-owned account with only public policy in JSON.
    /// Secret root/binding bytes cross the FFI in dedicated byte buffers;
    /// linked devices receive public descriptors and no root at all.
    private func ensureAccountWallet() async throws -> OpenCsvAccountWallet {
        if let accountWallet {
            return accountWallet
        }

        let isPrimary = DependenciesBridge.shared.tsAccountManager
            .registrationStateWithMaybeSneakyTransaction.isPrimaryDevice == true
        let settings = try db.read { tx -> (
            network: String,
            esplora: String,
            peers: [String],
            observationChecks: [OpenCsvObservationCheck],
            backupPayload: OpenCsvSecureBackupPayload?,
            linked: OpenCsvLinkedWatchAccount?
        ) in
            let network = store.network(tx: tx)
            let configuredPeers = store.spvPeers(tx: tx)
            let peers = Self.effectiveSpvPeers(configured: configuredPeers, network: network)
            let backupPayload = try store.secureBackupPayload(tx: tx)
            return (
                network,
                store.esploraUrl(tx: tx),
                peers,
                store.observationChecks(tx: tx),
                backupPayload,
                try store.linkedWatchAccount(tx: tx),
            )
        }
        guard Self.isConsumerProductConfigured(for: settings.network) else {
            throw OpenCsvPaymentsError.productionUsdNotConfigured
        }

        let material: OpenCsvAccountMaterial?
        let role: OpenCsvAccountRole
        if isPrimary {
            material = try store.createPrimaryAccountMaterial()
            role = .primary
        } else {
            guard settings.linked != nil else {
                throw OpenCsvPaymentsError.linkedWalletNotProvisioned
            }
            material = nil
            role = .linked
        }

        let directory = Self.accountDatabaseDirectory(
            base: OWSFileSystem.appSharedDataDirectoryURL(),
        )
        guard OWSFileSystem.ensureDirectoryExists(directory.path) else {
            throw OpenCsvPaymentsError.couldNotPersistPendingSend(
                underlying: "could not create OpenCSV account directory",
            )
        }
        let databasePath = directory
            .appendingPathComponent(
                isPrimary
                    ? "account-v2.sqlite"
                    : "linked-account-v2-\(settings.linked?.owner ?? "unprovisioned").sqlite",
            )
            .path
        func openAccount(expectedCommitment: String?) throws -> OpenCsvAccountWallet {
            let config = OpenCsvAccountConfig(
                network: settings.network,
                esploraUrl: settings.esplora,
                peers: settings.peers,
                verificationPeers: settings.peers,
                role: role,
                // Rust persists successful verification. A fresh account always
                // starts frozen until Signal completes an actual export below.
                backupVerified: false,
                expectedDeviceBindingCommitment: expectedCommitment,
                observationChecks: settings.observationChecks,
                watchExternalDescriptor: settings.linked?.externalDescriptor,
                watchInternalDescriptor: settings.linked?.internalDescriptor,
                watchOwner: settings.linked?.owner,
                // Exact public manifests reviewed into this build. The signet
                // preview is test-only; mainnet deliberately remains empty.
                // Issuer keys and issuance operations never enter Signal.
                usdIssuers: OpenCsvReviewedUsdIssuers.policies(for: settings.network),
            )
            return try OpenCsvAccountWallet(
                config: config,
                accountRoot: material?.accountRoot ?? Data(),
                deviceBinding: material?.deviceBinding,
                databasePath: databasePath,
            )
        }

#if DEBUG && OPENCSV_TEST_WALLET_RECOVERY
        let pendingRebind = isPrimary ? try store.pendingTestDeviceRebind() : nil
        let account: OpenCsvAccountWallet
        do {
            // Before Rust's transactional rebind, the database still names
            // the restored commitment. This is the common path.
            account = try openAccount(
                expectedCommitment: settings.backupPayload?.deviceBindingCommitment,
            )
        } catch {
            // A process may die after Rust commits the new commitment but
            // before Signal advances its Keychain stage. The planned record
            // already contains the deterministic replacement commitment, so
            // retry exactly that one value and no arbitrary fallback.
            guard let pendingRebind else { throw error }
            account = try openAccount(expectedCommitment: pendingRebind.newDeviceBindingCommitment)
        }
#else
        let account = try openAccount(
            expectedCommitment: settings.backupPayload?.deviceBindingCommitment,
        )
#endif
        if material?.isRestoredReadOnly == true, let payload = settings.backupPayload {
            let currentCommitment = try account.status().deviceBinding.commitment
            // Once a test rebind has committed, the old checkpoint is still
            // retained only as recovery provenance and must not be imported
            // over the replacement commitment on restart.
            if currentCommitment == payload.deviceBindingCommitment {
                _ = try account.restoreCheckpoint(payload.checkpointJson)
            }
        }
        if !secureBackupIsEnabled() {
            _ = try account.setBackupState(
                verified: false,
                checkpointVersion: OpenCsvReviewedUsdIssuers.testUsdCheckpointVersion,
            )
        }
        if isPrimary {
            let status = try account.status()
            guard let owner = status.owners.first else {
                throw OpenCsvClientError.decode("primary account returned no owner identity")
            }
            let watchAccount = OpenCsvLinkedWatchAccount(
                externalDescriptor: status.watchDescriptors.external,
                internalDescriptor: status.watchDescriptors.internal,
                owner: owner,
            )
            guard watchAccount.isValidForLinkedProvisioning else {
                throw OpenCsvClientError.decode("primary account returned invalid public watch material")
            }
            let changed = try await db.awaitableWrite { tx in
                let changed = try store.linkedWatchAccount(tx: tx) != watchAccount
                if changed {
                    try store.setLinkedWatchAccount(watchAccount, tx: tx)
                }
                return changed
            }
            if changed {
                SSKEnvironment.shared.syncManagerRef.sendConfigurationSyncMessage()
            }
        }
        accountWallet = account
        return account
    }

    /// A linked device received fresh public descriptors over Signal's
    /// authenticated device-sync channel. Drop only the process-local handle;
    /// the watch database is namespaced by owner and remains rebuildable.
    public func linkedWatchAccountDidChange() {
        accountWallet = nil
    }

    /// Refresh the read-rich fee wallet through its non-authoritative
    /// Esplora accelerator. Selected spend state is still rechecked through
    /// compact-filter/full-block verification by Rust before signing.
    public func syncAccount() async throws -> OpenCsvAccountSyncReport {
        let account = try await ensureAccountWallet()
        let report = try account.sync()
        do {
            try await maintainBatchReserves(
                account: account,
                participantCount: 2,
                createIfMissing: true,
            )
        } catch {
            // A read refresh must remain usable with too little fee reserve
            // or while observers are offline. The Advanced wallet receipt
            // exposes the maintenance state and the next foreground pass
            // resumes the exact persisted transaction.
            Logger.warn("OpenCSV count-2 reserve maintenance is pending: \(error)")
        }
        return report
    }

    /// Keep one small stock of count-specific C1 inputs ahead of the send
    /// path. The split has no arbitrary recipient surface: Rust creates only
    /// reviewed stock outputs, derived fee cells, and wallet change.
    private func maintainBatchReserves(
        account: OpenCsvAccountWallet,
        participantCount: UInt8,
        createIfMissing: Bool,
    ) async throws {
        var status = try account.status()
        guard
            status.role == .primary,
            status.writeEnabled,
            ["signet", "regtest"].contains(status.network)
        else { return }
        if
            status.batchReserves?.inventory.contains(where: {
                $0.participantCount == participantCount
                    && ["available", "reserved", "signature_released"].contains($0.state)
                    && $0.count > 0
            }) == true
        {
            return
        }

        let maintenance = status.batchReserves?.maintenanceOperations
            .first { operation in
                operation.participantCount == participantCount
                    && ["signed_persisted", "broadcast_unobserved", "mempool"].contains(operation.state)
            }
        if let current = maintenance {
            // Confirmation is stronger than unconfirmed observer evidence and
            // makes an RBF unnecessary. Ask Rust to verify it first so an API
            // outage cannot strand already-mined reserve stock behind the
            // unconfirmed two-observer gate.
            var refreshed: OpenCsvBatchReserveOperation?
            do {
                refreshed = try account.refreshBatchReserves(current.maintenanceId)
                if refreshed?.state == "confirmed" {
                    return
                }
            } catch {
                Logger.warn("OpenCSV reserve confirmation check is pending: \(error)")
            }
            var resumed: OpenCsvBatchReserveOperation
            if
                OpenCsvBatchReservePolicy.shouldFeeBump(
                    state: refreshed?.state ?? current.state,
                    feeRateSatPerVb: refreshed?.feeRateSatPerVb ?? current.feeRateSatPerVb,
                )
            {
                resumed = try account.feeBumpBatchReserves(
                    current.maintenanceId,
                    targetSatPerVb: OpenCsvBatchReservePolicy.targetSatPerVb,
                )
                // The replacement and stock txid remap are already durable
                // before relay. Preserve that exact recovery point promptly.
                try await backUpAccountCheckpoint(account: account)
            } else {
                resumed = try account.resumeBatchReserves(current.maintenanceId)
            }
            if resumed.state == "signed_persisted" || resumed.state == "broadcast_unobserved" {
                resumed = try await observeBatchReserveIfAvailable(account: account, operation: resumed)
            }
            if resumed.state == "mempool" {
                _ = try account.refreshBatchReserves(resumed.maintenanceId)
            }
            return
        }
        guard createIfMissing else { return }

        let prepared = try account.prepareBatchReserves(
            participantCount: participantCount,
            targetSatPerVb: OpenCsvBatchReservePolicy.targetSatPerVb,
            maxFeeSats: 2_000,
        )
        // The exact signed split is already durable before Rust relays it.
        // Export its checkpoint promptly so a restored test wallet retains
        // the maintenance receipt and can resume observation by txid.
        try await backUpAccountCheckpoint(account: account)
        _ = try await observeBatchReserveIfAvailable(account: account, operation: prepared)
        status = try account.status()
        if
            status.batchReserves?.maintenanceOperations.contains(where: {
                $0.maintenanceId == prepared.maintenanceId
            }) == true
        {
            requestBackgroundWorkScheduling()
        }
    }

    private func observeBatchReserveIfAvailable(
        account: OpenCsvAccountWallet,
        operation: OpenCsvBatchReserveOperation,
    ) async throws -> OpenCsvBatchReserveOperation {
        let status = try account.status()
        guard status.network == "signet" else { return operation }
        let policy = status.observationPolicy
            ?? db.read { self.store.observationChecks(tx: $0) }
        let observation = try await OpenCsvPinnedObserver.observeSignetTransaction(
            txid: operation.txid,
            policy: policy,
        )
        return try account.observeBatchReserves(
            maintenanceId: operation.maintenanceId,
            rawTransaction: observation.rawTransaction,
            observations: observation.evidence,
        )
    }

#if DEBUG && OPENCSV_TEST_WALLET_RECOVERY
    /// Resume the complete test-only restored-device rebind transaction.
    /// Every secret-bearing stage lives in Keychain; the Rust database and
    /// the Secure Backup payload can therefore be reconciled after a crash
    /// without generating a second binding or changing the account root.
    public func completeTestWalletRecovery() async throws {
        guard secureBackupIsEnabled() else {
            throw OpenCsvPaymentsError.secureBackupRequired
        }
        let payload = try db.read { tx in
            try self.store.secureBackupPayload(tx: tx)
        }
        guard let payload else {
            throw OpenCsvPaymentsError.secureBackupFailed(
                underlying: "restored backup has no OpenCSV checkpoint",
            )
        }
        var pending = try store.pendingTestDeviceRebind()
            ?? store.beginTestDeviceRebind(payload: payload)
        let account = try await ensureAccountWallet()
        let before = try account.status()
        guard
            before.role == .primary,
            ["signet", "regtest"].contains(before.network)
        else {
            throw OpenCsvPaymentsError.secureBackupFailed(
                underlying: "test wallet recovery is limited to a primary signet/regtest wallet",
            )
        }

        // The final stage may have completed immediately before a crash.
        // Rust's write gate is the durable evidence; clearing the local
        // resume record is then the only remaining action.
        if before.writeEnabled, pending.stage == .backupStaged {
            try store.finishTestDeviceRebind()
            return
        }

        let response = try account.rebindTestDevice(
            deviceBinding: pending.newDeviceBinding,
        )
        guard
            !response.writeEnabled,
            response.backupRequired,
            response.deviceBindingCommitment == pending.newDeviceBindingCommitment,
            response.checkpoint.checkpointHash != pending.sourceCheckpointHash,
            response.checkpoint.checkpoint.network == before.network,
            response.checkpoint.checkpoint.rootFingerprint == before.rootFingerprint,
            response.checkpoint.checkpoint.owners == before.owners,
            response.checkpoint.checkpoint.deviceBindingCommitment
            == pending.newDeviceBindingCommitment
        else {
            throw OpenCsvPaymentsError.secureBackupFailed(
                underlying: "test rebind returned inconsistent identity or checkpoint data",
            )
        }
        let afterRebind = try account.status()
        guard
            afterRebind.rootFingerprint == before.rootFingerprint,
            afterRebind.owners == before.owners,
            afterRebind.assets == before.assets,
            afterRebind.depositAddress == before.depositAddress
        else {
            throw OpenCsvPaymentsError.secureBackupFailed(
                underlying: "test rebind changed wallet identity, assets, or deposit address",
            )
        }

        pending.stage = .checkpointReady
        pending.checkpointJson = response.checkpointJson
        pending.checkpointHash = response.checkpoint.checkpointHash
        try store.setPendingTestDeviceRebind(pending)

        try store.installReboundAccountMaterial(
            root: payload.accountRoot,
            binding: pending.newDeviceBinding,
        )
        pending.stage = .materialInstalled
        try store.setPendingTestDeviceRebind(pending)

        let replacementPayload = try OpenCsvSecureBackupPayload(
            version: response.checkpoint.checkpoint.version,
            accountRoot: payload.accountRoot,
            checkpointJson: response.checkpointJson,
            checkpointHash: response.checkpoint.checkpointHash,
            deviceBindingCommitment: response.deviceBindingCommitment,
        )
        try await db.awaitableWrite { tx in
            try self.store.setSecureBackupPayload(replacementPayload, tx: tx)
        }
        pending.stage = .backupStaged
        try store.setPendingTestDeviceRebind(pending)

        do {
            try await DependenciesBridge.shared.backupExportJobRunner
                .startIfNecessary(mode: .manual).value
            _ = try account.setBackupState(
                verified: true,
                checkpointVersion: replacementPayload.version,
            )
            try store.finishTestDeviceRebind()
        } catch {
            // The signed wallet remains frozen. The Keychain stage and exact
            // replacement checkpoint intentionally remain for an idempotent
            // retry; no new binding is generated.
            throw OpenCsvPaymentsError.secureBackupFailed(underlying: "\(error)")
        }
    }
#endif

    private func secureBackupIsEnabled() -> Bool {
        db.read { tx in
            switch DependenciesBridge.shared.backupPlanManager.backupPlan(tx: tx) {
            case .disabled, .disabling:
                return false
            case .free, .paid, .paidExpiringSoon, .paidAsTester:
                return true
            }
        }
    }

    /// Stage the exact Rust checkpoint in Signal's backup frame and wait for
    /// a completed manual export. Only then does Rust unfreeze writes or
    /// acknowledge the exact checkpoint that Signal actually backed up.
    ///
    /// Receive/finality state can legitimately advance after a proof was
    /// prepared. In that case we back up the newest complete wallet state;
    /// Rust atomically checks that hash while the operation remains
    /// proof-ready, without regenerating the unchanged proof.
    private func backUpAccountCheckpoint(
        account: OpenCsvAccountWallet,
        operationId: String? = nil,
        batchLocalId: String? = nil,
        expectedCheckpointHash: String? = nil,
    ) async throws {
        guard secureBackupIsEnabled() else {
            _ = try? account.setBackupState(
                verified: false,
                checkpointVersion: OpenCsvReviewedUsdIssuers.testUsdCheckpointVersion,
            )
            throw OpenCsvPaymentsError.secureBackupRequired
        }
        guard let material = try store.accountMaterial() else {
            throw OpenCsvPaymentsError.secureBackupFailed(underlying: "missing primary account root")
        }
        let checkpointJson = try account.checkpointJson()
        let checkpoint = try account.checkpoint()
        guard let commitment = checkpoint.checkpoint.deviceBindingCommitment else {
            throw OpenCsvPaymentsError.secureBackupFailed(underlying: "checkpoint has no device binding")
        }
        if let expectedCheckpointHash, expectedCheckpointHash != checkpoint.checkpointHash {
            Logger.info(
                "OpenCSV wallet checkpoint advanced after proof preparation; protecting the current state",
            )
        }
        let payload = try OpenCsvSecureBackupPayload(
            version: checkpoint.checkpoint.version,
            accountRoot: material.accountRoot,
            checkpointJson: checkpointJson,
            checkpointHash: checkpoint.checkpointHash,
            deviceBindingCommitment: commitment,
        )
        do {
            try await db.awaitableWrite { tx in
                try self.store.setSecureBackupPayload(payload, tx: tx)
            }
            try await DependenciesBridge.shared.backupExportJobRunner
                .startIfNecessary(mode: .manual).value
            _ = try account.setBackupState(verified: true, checkpointVersion: payload.version)
            if let operationId {
                try account.acknowledgeBackup(
                    operationId: operationId,
                    checkpointHash: checkpoint.checkpointHash,
                )
            }
            if let batchLocalId {
                _ = try account.acknowledgeSendBatchBackup(
                    batchLocalId: batchLocalId,
                    checkpointHash: checkpoint.checkpointHash,
                )
            }
        } catch let error as OpenCsvPaymentsError {
            throw error
        } catch {
            throw OpenCsvPaymentsError.secureBackupFailed(underlying: "\(error)")
        }
    }

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
        let peers = db.read { tx in
            let network = self.store.network(tx: tx)
            return Self.effectiveSpvPeers(
                configured: self.store.spvPeers(tx: tx),
                network: network,
            )
        }
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
                    Logger.warn("scan-index snapshot export failed; falling back to cache: \(error)")
                }
            }
        }
        if let cached = db.read(block: { store.lastSnapshotJson(tx: $0) }) {
            return cached
        }
        // Empty demo snapshot is compatibility-only for a wallet with no
        // stored history. Production verification never falls back from a
        // missing phone-owned chain view to an OpenCSV-specific server.
        return #"{"tip_height":0,"entries":[]}"#
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
