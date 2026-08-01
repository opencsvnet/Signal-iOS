//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Which side of a payment this wallet is on.
public enum OpenCsvPaymentDirection: String, Codable {
    /// Credits coins we own.
    case incoming
    /// We sent it; `amount` is what went to the recipient, not the change.
    case outgoing
    /// It verifies, but pays neither us nor (as far as we can tell) the
    /// other party in this chat — e.g. a consignment forwarded into the
    /// conversation. Rendering it as a credit would be a lie.
    case thirdParty
}

/// A stored verification verdict for one consignment attachment, keyed by
/// attachment id. What the conversation cell renders.
public struct OpenCsvVerdictRecord: Codable, Equatable {
    public let status: String
    public let reason: String?
    /// The amount to display: credited for `incoming`, sent for `outgoing`.
    public let amount: UInt64
    public let currency: String?
    public let assetId: String?
    public let direction: OpenCsvPaymentDirection
    public let verifiedAt: Date

    public var isVerified: Bool { status == "verified" }

    /// A verdict for a consignment someone sent us.
    ///
    /// A verified consignment that credits none of our coins is
    /// `thirdParty`, not a zero-value credit.
    public init(verdict: OpenCsvVerdict, date: Date) {
        let credits = verdict.credits ?? []
        self.status = verdict.status
        self.reason = verdict.reason
        self.amount = credits.reduce(0) { $0 + $1.amount }
        self.currency = credits.first?.currency
        self.assetId = credits.first?.assetId
        self.direction = credits.isEmpty ? .thirdParty : .incoming
        self.verifiedAt = date
    }

    /// A verdict for a consignment we sent. The amount is what the
    /// recipient receives — the self-ingest only ever credits our change,
    /// so deriving it from credits would show the wrong number.
    public init(sentAmount: UInt64, currency: String?, assetId: String?, date: Date) {
        self.status = "verified"
        self.reason = nil
        self.amount = sentAmount
        self.currency = currency
        self.assetId = assetId
        self.direction = .outgoing
        self.verifiedAt = date
    }
}

/// Persistence for the OpenCSV wallet, following SSK store conventions:
///
/// - **Secrets** live in the iOS Keychain (never on disk in plaintext),
///   via the app's `KeychainStorage`.
/// - **Consignments and verdicts** live in the (SQLCipher-encrypted) GRDB
///   database through a `KeyValueStore`: the raw blob and verdict of every
///   verified consignment, plus the ordered replay list and the spent-coin
///   set. Coins themselves are *not* persisted — the in-memory wallet is
///   rebuilt at startup by replaying stored blobs through the (fast)
///   verifier and re-marking spends, so persisted state can never disagree
///   with what the prover actually accepts.
///
/// Replay entries are string keys: `a:<attachmentId>` for received
/// consignments, `o:<ordinal>` for our own outgoing consignments (ingested
/// to credit change outputs).
public struct OpenCsvWalletStore {
    private static let collection = "OpenCsvPayments"
    private static let keychainService = "OpenCsvPayments"
    private static let keychainKey = "walletSecrets"

    private static let anchorServerUrlKey = "anchorServerUrl"
    private static let pendingDeliveriesKey = "pendingDeliveries"
    private static let replayOrderKey = "replayOrder"
    private static let spentCoinIdsKey = "spentCoinIds"
    private static let lastSnapshotKey = "lastSnapshot"
    private static let outgoingOrdinalKey = "outgoingOrdinal"

    private let keyValueStore = KeyValueStore(collection: Self.collection)
    private let keychainStorage: any KeychainStorage

    public init(keychainStorage: any KeychainStorage) {
        self.keychainStorage = keychainStorage
    }

    // MARK: - Secrets (Keychain)

    public func walletSecrets() throws -> String? {
        do {
            let data = try keychainStorage.dataValue(service: Self.keychainService, key: Self.keychainKey)
            return String(data: data, encoding: .utf8)
        } catch KeychainError.notFound {
            return nil
        }
    }

    public func setWalletSecrets(_ secretsJson: String) throws {
        try keychainStorage.setDataValue(Data(secretsJson.utf8), service: Self.keychainService, key: Self.keychainKey)
    }

    // MARK: - Settings

    public func anchorServerUrl(tx: DBReadTransaction) -> URL? {
        guard let string = keyValueStore.getString(Self.anchorServerUrlKey, transaction: tx), !string.isEmpty else {
            return nil
        }
        return URL(string: string)
    }

    public func setAnchorServerUrl(_ urlString: String?, tx: DBWriteTransaction) {
        keyValueStore.setString(urlString, key: Self.anchorServerUrlKey, transaction: tx)
    }

    // MARK: - Snapshot cache (for offline startup replay)

    public func lastSnapshotJson(tx: DBReadTransaction) -> String? {
        keyValueStore.getString(Self.lastSnapshotKey, transaction: tx)
    }

    public func setLastSnapshotJson(_ json: String, tx: DBWriteTransaction) {
        keyValueStore.setString(json, key: Self.lastSnapshotKey, transaction: tx)
    }

    // MARK: - Verdicts and blobs

    public func verdict(attachmentId: Attachment.IDType, tx: DBReadTransaction) -> OpenCsvVerdictRecord? {
        do {
            return try keyValueStore.getCodableValue(forKey: Self.verdictKey(attachmentId), transaction: tx)
        } catch {
            owsFailDebug("could not decode the OpenCSV verdict for attachment \(attachmentId): \(error)")
            return nil
        }
    }

    /// Record a verdict for a received attachment (and, when verified, its
    /// blob for startup replay).
    public func setVerdict(
        _ record: OpenCsvVerdictRecord,
        blob: Data?,
        attachmentId: Attachment.IDType,
        tx: DBWriteTransaction,
    ) {
        do {
            try keyValueStore.setCodable(record, key: Self.verdictKey(attachmentId), transaction: tx)
        } catch {
            owsFailDebug("could not persist an OpenCSV verdict: \(error)")
        }
        guard record.isVerified, let blob else { return }
        appendReplayEntry("a:\(attachmentId)", blob: blob, tx: tx)
    }

    /// Record one of our own outgoing consignments (replayed to re-credit
    /// change outputs) and the coins it spent. Returns the replay entry the
    /// blob is stored under, so a pending delivery can reference it instead
    /// of keeping a second copy.
    @discardableResult
    public func recordOutgoing(blob: Data, spends: [String], tx: DBWriteTransaction) throws -> String {
        let ordinal = keyValueStore.getUInt64(Self.outgoingOrdinalKey, defaultValue: 0, transaction: tx) + 1
        keyValueStore.setUInt64(ordinal, key: Self.outgoingOrdinalKey, transaction: tx)
        let entry = "o:\(ordinal)"
        appendReplayEntry(entry, blob: blob, tx: tx)
        try addSpentCoinIds(spends, tx: tx)
        return entry
    }

    /// The consignment bytes stored under a replay entry.
    public func blob(forReplayEntry entry: String, tx: DBReadTransaction) -> Data? {
        keyValueStore.getData(Self.blobKey(entry), transaction: tx)
    }

    /// Replay entries in ingestion order, with their blobs.
    public func replayBlobs(tx: DBReadTransaction) -> [(entry: String, blob: Data)] {
        replayOrder(tx: tx).compactMap { entry in
            keyValueStore.getData(Self.blobKey(entry), transaction: tx).map { (entry, $0) }
        }
    }

    /// The replay order. A decode failure here would silently orphan every
    /// stored consignment, so it is reported rather than read as empty.
    private func replayOrder(tx: DBReadTransaction) -> [String] {
        do {
            return try keyValueStore.getCodableValue(forKey: Self.replayOrderKey, transaction: tx) ?? []
        } catch {
            owsFailDebug("could not decode the OpenCSV replay order: \(error)")
            return []
        }
    }

    private func appendReplayEntry(_ entry: String, blob: Data, tx: DBWriteTransaction) {
        keyValueStore.setData(blob, key: Self.blobKey(entry), transaction: tx)
        var order = replayOrder(tx: tx)
        if !order.contains(entry) {
            order.append(entry)
            do {
                try keyValueStore.setCodable(order, key: Self.replayOrderKey, transaction: tx)
            } catch {
                // The blob is stored but unreferenced: it will not be
                // replayed, so the coins it credits go missing at restart.
                owsFailDebug("could not record OpenCSV replay entry \(entry): \(error)")
            }
        }
    }

    // MARK: - Pending deliveries

    /// Attempts after which a delivery stops being retried automatically.
    /// It is *kept*, not discarded: the consignment is the only copy of a
    /// payment that already happened on-chain.
    public static let maxDeliveryAttempts = 8

    /// A consignment that has been anchored on-chain but whose message has
    /// not yet reached the send pipeline.
    ///
    /// Anchoring is irreversible: the moment the transfer confirms, the
    /// consumed coins are spent whether or not the recipient ever receives
    /// the consignment. So this record is written in the same transaction
    /// as the spend, and cleared only in the same transaction that inserts
    /// the message — never merely because a send was requested.
    ///
    /// The bytes live once, under `replayEntry`; keeping a second copy here
    /// would double ~47 KB per payment for no benefit.
    public struct PendingDelivery: Codable, Equatable {
        public let id: String
        public let threadUniqueId: String
        public let body: String
        /// Replay entry holding the consignment bytes.
        public let replayEntry: String
        /// Amount sent to the recipient, for the outgoing verdict.
        public let amount: UInt64
        public let currency: String?
        public let assetId: String?
        public let createdAt: Date
        /// Delivery attempts so far; at `maxDeliveryAttempts` automatic
        /// retries stop.
        public var attempts: Int

        public var hasExhaustedRetries: Bool { attempts >= OpenCsvWalletStore.maxDeliveryAttempts }

        public init(
            id: String = UUID().uuidString,
            threadUniqueId: String,
            body: String,
            replayEntry: String,
            amount: UInt64,
            currency: String?,
            assetId: String?,
            createdAt: Date,
            attempts: Int = 0,
        ) {
            self.id = id
            self.threadUniqueId = threadUniqueId
            self.body = body
            self.replayEntry = replayEntry
            self.amount = amount
            self.currency = currency
            self.assetId = assetId
            self.createdAt = createdAt
            self.attempts = attempts
        }
    }

    /// Every undelivered consignment, oldest first.
    ///
    /// A decode failure drops that one record from the result and is
    /// reported — it must never be allowed to look like "the queue is
    /// empty", which would silently strand every queued payment.
    public func pendingDeliveries(tx: DBReadTransaction) -> [PendingDelivery] {
        pendingDeliveryIds(tx: tx).compactMap { id in
            do {
                guard let delivery: PendingDelivery = try keyValueStore.getCodableValue(
                    forKey: Self.pendingDeliveryKey(id),
                    transaction: tx,
                ) else {
                    owsFailDebug("pending OpenCSV delivery \(id) is indexed but missing")
                    return nil
                }
                return delivery
            } catch {
                owsFailDebug("could not decode pending OpenCSV delivery \(id): \(error)")
                return nil
            }
        }
    }

    public func addPendingDelivery(_ delivery: PendingDelivery, tx: DBWriteTransaction) throws {
        try keyValueStore.setCodable(delivery, key: Self.pendingDeliveryKey(delivery.id), transaction: tx)
        var ids = pendingDeliveryIds(tx: tx)
        if !ids.contains(delivery.id) {
            ids.append(delivery.id)
            try keyValueStore.setCodable(ids, key: Self.pendingDeliveriesKey, transaction: tx)
        }
    }

    /// Persist a changed attempt count. Best-effort: losing it costs an
    /// extra retry, never a payment.
    public func updatePendingDelivery(_ delivery: PendingDelivery, tx: DBWriteTransaction) {
        do {
            try keyValueStore.setCodable(delivery, key: Self.pendingDeliveryKey(delivery.id), transaction: tx)
        } catch {
            owsFailDebug("could not update pending OpenCSV delivery \(delivery.id): \(error)")
        }
    }

    /// Clear a delivery. Only ever called in the same transaction that
    /// inserts the message carrying it.
    public func removePendingDelivery(id: String, tx: DBWriteTransaction) throws {
        keyValueStore.removeValue(forKey: Self.pendingDeliveryKey(id), transaction: tx)
        var ids = pendingDeliveryIds(tx: tx)
        ids.removeAll { $0 == id }
        try keyValueStore.setCodable(ids, key: Self.pendingDeliveriesKey, transaction: tx)
    }

    private func pendingDeliveryIds(tx: DBReadTransaction) -> [String] {
        do {
            return try keyValueStore.getCodableValue(forKey: Self.pendingDeliveriesKey, transaction: tx) ?? []
        } catch {
            owsFailDebug("could not decode the pending OpenCSV delivery index: \(error)")
            return []
        }
    }

    // MARK: - Spent coins

    /// Coins already spent. A decode failure must not read as "nothing is
    /// spent" — that would present spent coins as spendable.
    public func spentCoinIds(tx: DBReadTransaction) -> [String] {
        do {
            return try keyValueStore.getCodableValue(forKey: Self.spentCoinIdsKey, transaction: tx) ?? []
        } catch {
            owsFailDebug("could not decode the OpenCSV spent-coin set: \(error)")
            return []
        }
    }

    /// Record coins as spent.
    ///
    /// Throws rather than swallowing: losing this write would leave coins
    /// that are spent on-chain looking spendable after the next restart,
    /// so the caller must fail the whole transaction instead.
    public func addSpentCoinIds(_ coinIds: [String], tx: DBWriteTransaction) throws {
        guard !coinIds.isEmpty else { return }
        var spent = spentCoinIds(tx: tx)
        for id in coinIds where !spent.contains(id) {
            spent.append(id)
        }
        try keyValueStore.setCodable(spent, key: Self.spentCoinIdsKey, transaction: tx)
    }

    private static func verdictKey(_ attachmentId: Attachment.IDType) -> String {
        "verdict:\(attachmentId)"
    }

    private static func pendingDeliveryKey(_ id: String) -> String {
        "pendingDelivery:\(id)"
    }

    private static func blobKey(_ entry: String) -> String {
        "blob:\(entry)"
    }
}
