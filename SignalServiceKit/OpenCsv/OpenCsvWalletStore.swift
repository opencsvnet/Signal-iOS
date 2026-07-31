//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// A stored verification verdict for one consignment attachment, keyed by
/// attachment id. What the conversation cell renders.
public struct OpenCsvVerdictRecord: Codable, Equatable {
    public let status: String
    public let reason: String?
    public let amount: UInt64
    public let currency: String?
    public let assetId: String?
    public let verifiedAt: Date

    public var isVerified: Bool { status == "verified" }

    public init(verdict: OpenCsvVerdict, date: Date) {
        self.status = verdict.status
        self.reason = verdict.reason
        self.amount = (verdict.credits ?? []).reduce(0) { $0 + $1.amount }
        self.currency = verdict.credits?.first?.currency
        self.assetId = verdict.credits?.first?.assetId
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
        try? keyValueStore.getCodableValue(forKey: Self.verdictKey(attachmentId), transaction: tx)
    }

    /// Record a verdict for a received attachment (and, when verified, its
    /// blob for startup replay).
    public func setVerdict(
        _ record: OpenCsvVerdictRecord,
        blob: Data?,
        attachmentId: Attachment.IDType,
        tx: DBWriteTransaction,
    ) {
        try? keyValueStore.setCodable(record, key: Self.verdictKey(attachmentId), transaction: tx)
        guard record.isVerified, let blob else { return }
        appendReplayEntry("a:\(attachmentId)", blob: blob, tx: tx)
    }

    /// Record one of our own outgoing consignments (replayed to re-credit
    /// change outputs) and the coins it spent.
    public func recordOutgoing(blob: Data, spends: [String], tx: DBWriteTransaction) {
        let ordinal = keyValueStore.getUInt64(Self.outgoingOrdinalKey, defaultValue: 0, transaction: tx) + 1
        keyValueStore.setUInt64(ordinal, key: Self.outgoingOrdinalKey, transaction: tx)
        appendReplayEntry("o:\(ordinal)", blob: blob, tx: tx)
        addSpentCoinIds(spends, tx: tx)
    }

    /// Replay entries in ingestion order, with their blobs.
    public func replayBlobs(tx: DBReadTransaction) -> [(entry: String, blob: Data)] {
        replayOrder(tx: tx).compactMap { entry in
            keyValueStore.getData(Self.blobKey(entry), transaction: tx).map { (entry, $0) }
        }
    }

    private func replayOrder(tx: DBReadTransaction) -> [String] {
        (try? keyValueStore.getCodableValue(forKey: Self.replayOrderKey, transaction: tx)) ?? []
    }

    private func appendReplayEntry(_ entry: String, blob: Data, tx: DBWriteTransaction) {
        keyValueStore.setData(blob, key: Self.blobKey(entry), transaction: tx)
        var order = replayOrder(tx: tx)
        if !order.contains(entry) {
            order.append(entry)
            try? keyValueStore.setCodable(order, key: Self.replayOrderKey, transaction: tx)
        }
    }

    // MARK: - Spent coins

    public func spentCoinIds(tx: DBReadTransaction) -> [String] {
        (try? keyValueStore.getCodableValue(forKey: Self.spentCoinIdsKey, transaction: tx)) ?? []
    }

    public func addSpentCoinIds(_ coinIds: [String], tx: DBWriteTransaction) {
        guard !coinIds.isEmpty else { return }
        var spent = spentCoinIds(tx: tx)
        for id in coinIds where !spent.contains(id) {
            spent.append(id)
        }
        try? keyValueStore.setCodable(spent, key: Self.spentCoinIdsKey, transaction: tx)
    }

    private static func verdictKey(_ attachmentId: Attachment.IDType) -> String {
        "verdict:\(attachmentId)"
    }

    private static func blobKey(_ entry: String) -> String {
        "blob:\(entry)"
    }
}
