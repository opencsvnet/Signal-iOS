//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
#if DEBUG && OPENCSV_TEST_WALLET_RECOVERY
import CryptoKit
#endif

/// Which side of a payment this wallet is on.
public enum OpenCsvPaymentDirection: String, Codable {
    /// Credits coins we own.
    case incoming
    /// We sent it; `amount` is what went to the recipient, not the change.
    case outgoing
    /// This account issued new units of an issuer-controlled asset.
    case minted
    /// It verifies, but pays neither us nor (as far as we can tell) the
    /// other party in this chat — e.g. a consignment forwarded into the
    /// conversation. Rendering it as a credit would be a lie.
    case thirdParty
}

/// Wallet activity for an incoming consignment. Transport/download remains
/// `.confirming` and nonspendable. `.awaitingObservers` preserves the amount
/// of a previously verified unconfirmed payment while required network
/// observations are temporarily unavailable; it is not spendable.
/// `.availableUnconfirmed` has passed the
/// complete proof, ownership, binding and settled-history checks and is in
/// Rust coin selection with an exact mempool-parent dependency. `.settled`
/// has met confirmation policy. The older `.available` spelling remains
/// decodable as settled activity for existing installs.
public enum OpenCsvIncomingActivityState: String, Codable {
    case confirming
    case awaitingObservers
    case availableUnconfirmed
    case available
    case settled
    case needsAttention

    public var isSpendable: Bool {
        switch self {
        case .availableUnconfirmed, .available, .settled:
            return true
        case .confirming, .awaitingObservers, .needsAttention:
            return false
        }
    }

    public var isSettled: Bool {
        self == .available || self == .settled
    }
}

public struct OpenCsvIncomingActivity: Codable, Equatable {
    public let attachmentId: Attachment.IDType
    public let threadUniqueId: String?
    public let messageUniqueId: String?
    public let state: OpenCsvIncomingActivityState
    public let amount: UInt64?
    public let currency: String?
    public let detail: String?
    public let firstSeenAt: Date
    public let updatedAt: Date
}

/// The last phone-owned chain view that completed verification. This is
/// presentation metadata, not consensus state: the actual filter/header index
/// remains the authority and is independently reopened for every update.
public struct OpenCsvVerifiedChainView: Codable, Equatable {
    public let tipHeight: UInt64
    public let observedAt: Date

    public init(tipHeight: UInt64, observedAt: Date) {
        self.tipHeight = tipHeight
        self.observedAt = observedAt
    }
}

/// Scheduling urgency is deliberately independent of BackgroundTasks so the
/// wallet's durable-state policy can be tested in SignalServiceKit.
public enum OpenCsvBackgroundWorkUrgency: Equatable {
    case never
    case immediate
    case monitor
}

public enum OpenCsvBackgroundWorkPolicy {
    public static func urgency(
        activityStates: [OpenCsvIncomingActivityState],
        hasPendingDelivery: Bool,
        hasPendingOperation: Bool,
        hasInFlightSend: Bool,
    ) -> OpenCsvBackgroundWorkUrgency {
        if
            hasPendingDelivery || hasPendingOperation || hasInFlightSend
            || activityStates.contains(.confirming)
            || activityStates.contains(.awaitingObservers)
        {
            return .immediate
        }
        if activityStates.contains(.availableUnconfirmed) {
            return .monitor
        }
        return .never
    }
}

/// A stored verification verdict for one consignment attachment, keyed by
/// attachment id. What the conversation cell renders.
public struct OpenCsvVerdictRecord: Codable, Equatable {
    static let currentVerificationVersion: UInt = 3

    /// Receiver-verification semantics that produced this verdict. Missing
    /// on historical records, which lets narrowly scoped migrations retry a
    /// verdict made by a verifier bug without replaying all definitive
    /// rejections forever.
    public let verificationVersion: UInt?
    public let status: String
    public let reason: String?
    /// The amount to display: credited for `incoming`, sent for `outgoing`.
    public let amount: UInt64
    public let currency: String?
    public let assetId: String?
    public let direction: OpenCsvPaymentDirection
    public let verifiedAt: Date
    /// Which chain view decided this verdict ("self-scan", "cross-check",
    /// "single-snapshot"). "self-scan" means no server was believed — the
    /// bubble may say so. Nil on records that predate the distinction.
    public let chainView: String?
    /// Canonical identity returned by Rust after decode/re-encode. Two
    /// byte-distinct attachments encoding the same consignment share this
    /// identity and therefore one logical verdict/payment cell.
    public let consignmentId: String?
    /// Stable logical payment identity. Unlike `consignmentId`, this is
    /// unchanged by a protocol-safe Bitcoin fee replacement.
    public let paymentId: String?
    public let supersededConsignmentIds: [String]?
    public let finality: String?
    public let spendable: Bool?
    public let anchorTxid: String?

    public var isVerified: Bool { status == "verified" }

    /// Protocol amounts use each instrument's smallest unit. Signal admits
    /// USD only through the reviewed six-decimal profile, so chat receipts
    /// must not expose `1_000_000` as though it meant one million dollars.
    public var formattedAmount: String {
        currency == "USD" ? OpenCsvUsdAmount.format(amount) : "\(amount)"
    }

    public var presentationCurrency: String {
        OpenCsvProductPresentation.currencyName(currency: currency, assetId: assetId)
    }

    /// A verdict for a consignment someone sent us.
    ///
    /// A verified consignment that credits none of our coins is
    /// `thirdParty`, not a zero-value credit.
    public init(verdict: OpenCsvVerdict, date: Date) {
        let credits = verdict.credits ?? []
        self.verificationVersion = Self.currentVerificationVersion
        self.status = verdict.status
        self.reason = verdict.reason
        self.amount = credits.reduce(0) { $0 + $1.amount }
        self.currency = credits.first?.currency
        self.assetId = credits.first?.assetId
        self.direction = credits.isEmpty ? .thirdParty : .incoming
        self.verifiedAt = date
        self.chainView = verdict.chainView
        self.consignmentId = verdict.consignmentId
        self.paymentId = verdict.paymentId
        self.supersededConsignmentIds = verdict.supersededConsignmentIds
        self.finality = verdict.finality
        self.spendable = verdict.spendable
        self.anchorTxid = verdict.anchorTxid
    }

    /// A verdict for a consignment we sent. The amount is what the
    /// recipient receives — the self-ingest only ever credits our change,
    /// so deriving it from credits would show the wrong number.
    public init(
        sentAmount: UInt64,
        currency: String?,
        assetId: String?,
        consignmentId: String? = nil,
        paymentId: String? = nil,
        supersededConsignmentIds: [String]? = nil,
        date: Date,
    ) {
        self.verificationVersion = Self.currentVerificationVersion
        self.status = "verified"
        self.reason = nil
        self.amount = sentAmount
        self.currency = currency
        self.assetId = assetId
        self.direction = .outgoing
        self.verifiedAt = date
        self.chainView = nil
        self.consignmentId = consignmentId
        self.paymentId = paymentId
        self.supersededConsignmentIds = supersededConsignmentIds
        self.finality = "settled"
        self.spendable = true
        self.anchorTxid = nil
    }

    /// A verdict retained for a legacy issuer operation created before
    /// Signal became owner-only. It is a credit, not an outgoing transfer,
    /// so old conversation receipts must never render it with a debit sign.
    public init(
        mintedAmount: UInt64,
        currency: String?,
        assetId: String?,
        consignmentId: String? = nil,
        paymentId: String? = nil,
        supersededConsignmentIds: [String]? = nil,
        date: Date,
    ) {
        self.verificationVersion = Self.currentVerificationVersion
        self.status = "verified"
        self.reason = nil
        self.amount = mintedAmount
        self.currency = currency
        self.assetId = assetId
        self.direction = .minted
        self.verifiedAt = date
        self.chainView = nil
        self.consignmentId = consignmentId
        self.paymentId = paymentId
        self.supersededConsignmentIds = supersededConsignmentIds
        self.finality = "settled"
        self.spendable = true
        self.anchorTxid = nil
    }
}

public enum OpenCsvAccountMaterialError: Error, Equatable {
    case invalidLength
    case conflictingAccountRoot
}

/// Secret material held by the primary installation. Fresh setup stores the
/// root and binding in one Keychain value so a crash cannot leave a half-made
/// account. Secure Backup recovery deliberately installs only the root; the
/// missing non-migratable binding therefore opens Rust read/export-only.
public struct OpenCsvAccountMaterial: Codable, Equatable {
    public let accountRoot: Data
    public let deviceBinding: Data?

    public var isRestoredReadOnly: Bool { deviceBinding == nil }

    public init(accountRoot: Data, deviceBinding: Data?) throws {
        guard accountRoot.count == 32, deviceBinding == nil || deviceBinding?.count == 32 else {
            throw OpenCsvAccountMaterialError.invalidLength
        }
        self.accountRoot = accountRoot
        self.deviceBinding = deviceBinding
    }
}

/// The wallet-owned payload passed to Signal Secure Backups. The BDK chain
/// database is intentionally absent; only the root and Rust's compact,
/// versioned checkpoint are recovery material.
public struct OpenCsvSecureBackupPayload: Codable, Equatable {
    public let version: UInt32
    public let accountRoot: Data
    public let checkpointJson: String
    public let checkpointHash: String
    public let deviceBindingCommitment: String

    public init(
        version: UInt32,
        accountRoot: Data,
        checkpointJson: String,
        checkpointHash: String,
        deviceBindingCommitment: String,
    ) throws {
        guard
            version == OpenCsvReviewedUsdIssuers.testUsdCheckpointVersion,
            accountRoot.count == 32
        else {
            throw OpenCsvAccountMaterialError.invalidLength
        }
        self.version = version
        self.accountRoot = accountRoot
        self.checkpointJson = checkpointJson
        self.checkpointHash = checkpointHash
        self.deviceBindingCommitment = deviceBindingCommitment
    }
}

#if DEBUG && OPENCSV_TEST_WALLET_RECOVERY
public struct OpenCsvPendingTestDeviceRebind: Codable, Equatable {
    public enum Stage: String, Codable, Equatable, Sendable {
        case planned
        case checkpointReady
        case materialInstalled
        case backupStaged
    }

    public let version: UInt32
    public let sourceCheckpointHash: String
    public let priorDeviceBindingCommitment: String
    public let newDeviceBinding: Data
    public let newDeviceBindingCommitment: String
    public var stage: Stage
    public var checkpointJson: String?
    public var checkpointHash: String?

    fileprivate init(
        sourceCheckpointHash: String,
        priorDeviceBindingCommitment: String,
        newDeviceBinding: Data,
        newDeviceBindingCommitment: String,
    ) {
        self.version = 1
        self.sourceCheckpointHash = sourceCheckpointHash
        self.priorDeviceBindingCommitment = priorDeviceBindingCommitment
        self.newDeviceBinding = newDeviceBinding
        self.newDeviceBindingCommitment = newDeviceBindingCommitment
        self.stage = .planned
        self.checkpointJson = nil
        self.checkpointHash = nil
    }
}
#endif

/// Public wallet material distributed to linked Signal devices. It is safe to
/// sync through Signal's device channel: no account root, issuer secret, or
/// Bitcoin signing material is present.
public struct OpenCsvLinkedWatchAccount: Codable, Equatable {
    public let externalDescriptor: String
    public let internalDescriptor: String
    public let owner: String

    public init(externalDescriptor: String, internalDescriptor: String, owner: String) {
        self.externalDescriptor = externalDescriptor
        self.internalDescriptor = internalDescriptor
        self.owner = owner
    }

    public var isValidForLinkedProvisioning: Bool {
        let descriptors = externalDescriptor.lowercased() + "\n" + internalDescriptor.lowercased()
        return owner.count == 64
            && owner.allSatisfy(\.isHexDigit)
            && externalDescriptor.hasPrefix("wpkh(")
            && internalDescriptor.hasPrefix("wpkh(")
            && externalDescriptor.utf8.count <= 2048
            && internalDescriptor.utf8.count <= 2048
            && externalDescriptor != internalDescriptor
            // Extended private keys must never cross Signal's linked-device
            // channel. BIP84 watch descriptors contain xpub/tpub variants;
            // every standardized extended-private variant contains `prv`.
            && !descriptors.contains("prv")
    }
}

/// Persistence for the OpenCSV wallet, following SSK store conventions:
///
/// - **Account secrets** live in the iOS Keychain (never on disk in
///   plaintext), via the app's `KeychainStorage`. That implementation uses
///   `AfterFirstUnlockThisDeviceOnly`; Secure Backup explicitly exports only
///   the account root, never the device binding.
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
    /// V2 never opens v1 KeyValueStore or Keychain state. The old namespace
    /// remains untouched for archival/export tooling and cannot be mistaken
    /// for a migrated wallet.
    private static let collection = "OpenCsvPayments.testUsd.v2"
    private static let keychainService = "OpenCsvPayments.testUsd.v2"
    private static let primaryAccountMaterialKey = "primaryAccountMaterial.v2"
    private static let restoredAccountRootKey = "restoredAccountRoot.v2"
#if DEBUG && OPENCSV_TEST_WALLET_RECOVERY
    private static let pendingTestDeviceRebindKey = "pendingTestDeviceRebind.v2"
#endif
    private static let keychainKey = "walletSecrets.v2"

    private static let anchorServerUrlKey = "anchorServerUrl"
    private static let esploraUrlKey = "esploraUrl.v2"
    private static let linkedWatchAccountKey = "linkedWatchAccount.v2"
    private static let pendingDeliveriesKey = "pendingDeliveries"
    private static let pendingAccountOperationsKey = "pendingAccountOperations.v2"
    private static let incomingActivitiesKey = "incomingActivities.v2"
    private static let inFlightSendsKey = "inFlightSends"
    private static let indexerUrlsKey = "indexerUrls"
    private static let spvPeersKey = "spvPeers"
    private static let scanFromHeightKey = "scanFromHeight"
    private static let networkKey = "network"
    private static let observationModesKey = "observationModes.v2"
    private static let replayOrderKey = "replayOrder"
    private static let spentCoinIdsKey = "spentCoinIds"
    private static let lastSnapshotKey = "lastSnapshot"
    private static let outgoingOrdinalKey = "outgoingOrdinal"
    private static let secureBackupPayloadKey = "secureBackupPayload.v2"
    private static let verifiedChainViewKey = "verifiedChainView.v2"
    private static let walletPresentationSnapshotKey = "walletPresentationSnapshot.v2"
    private static let attachmentConsignmentIdPrefix = "attachmentConsignmentId:"
    private static let canonicalPresentationAttachmentPrefix = "canonicalPresentationAttachment:"
    private static let canonicalPresentationMessagePrefix = "canonicalPresentationMessage:"

    private let keyValueStore = KeyValueStore(collection: Self.collection)
    private let keychainStorage: any KeychainStorage

    public init(keychainStorage: any KeychainStorage) {
        self.keychainStorage = keychainStorage
    }

    // MARK: - Signal-native account material (Keychain)

    public func accountMaterial() throws -> OpenCsvAccountMaterial? {
        do {
            let data = try keychainStorage.dataValue(
                service: Self.keychainService,
                key: Self.primaryAccountMaterialKey,
            )
            let material = try JSONDecoder().decode(OpenCsvAccountMaterial.self, from: data)
            // A fresh combined record must always contain both values. A
            // nil binding is represented only by the root-only recovery key.
            guard material.deviceBinding != nil else {
                throw OpenCsvAccountMaterialError.invalidLength
            }
            return try OpenCsvAccountMaterial(
                accountRoot: material.accountRoot,
                deviceBinding: material.deviceBinding,
            )
        } catch KeychainError.notFound {
            do {
                let root = try keychainStorage.dataValue(
                    service: Self.keychainService,
                    key: Self.restoredAccountRootKey,
                )
                return try OpenCsvAccountMaterial(accountRoot: root, deviceBinding: nil)
            } catch KeychainError.notFound {
                return nil
            }
        }
    }

    /// Atomically create root + binding for a genuinely fresh account. If a
    /// root was restored without its binding, this returns that read-only
    /// state and never manufactures a replacement binding.
    public func createPrimaryAccountMaterial() throws -> OpenCsvAccountMaterial {
        try createPrimaryAccountMaterial { Randomness.generateRandomBytes(UInt($0)) }
    }

    func createPrimaryAccountMaterial(
        randomBytes: (Int) -> Data,
    ) throws -> OpenCsvAccountMaterial {
        if let existing = try accountMaterial() {
            return existing
        }
        let material = try OpenCsvAccountMaterial(
            accountRoot: randomBytes(32),
            deviceBinding: randomBytes(32),
        )
        let encoded = try JSONEncoder().encode(material)
        try keychainStorage.setDataValue(
            encoded,
            service: Self.keychainService,
            key: Self.primaryAccountMaterialKey,
        )
        return material
    }

    /// Install the root restored by Signal Secure Backup. Existing material
    /// is never replaced; a conflicting root is a hard recovery error.
    public func installRestoredAccountRoot(_ root: Data) throws {
        guard root.count == 32 else {
            throw OpenCsvAccountMaterialError.invalidLength
        }
        if let existing = try accountMaterial() {
            guard existing.accountRoot == root else {
                throw OpenCsvAccountMaterialError.conflictingAccountRoot
            }
            return
        }
        try keychainStorage.setDataValue(
            root,
            service: Self.keychainService,
            key: Self.restoredAccountRootKey,
        )
    }

#if DEBUG && OPENCSV_TEST_WALLET_RECOVERY
    public func pendingTestDeviceRebind() throws -> OpenCsvPendingTestDeviceRebind? {
        do {
            let data = try keychainStorage.dataValue(
                service: Self.keychainService,
                key: Self.pendingTestDeviceRebindKey,
            )
            let pending = try JSONDecoder().decode(OpenCsvPendingTestDeviceRebind.self, from: data)
            guard pending.version == 1, pending.newDeviceBinding.count == 32 else {
                throw OpenCsvAccountMaterialError.invalidLength
            }
            return pending
        } catch KeychainError.notFound {
            return nil
        }
    }

    public func beginTestDeviceRebind(
        payload: OpenCsvSecureBackupPayload,
        randomBytes: (Int) -> Data = { Randomness.generateRandomBytes(UInt($0)) },
    ) throws -> OpenCsvPendingTestDeviceRebind {
        if let existing = try pendingTestDeviceRebind() {
            guard
                existing.sourceCheckpointHash == payload.checkpointHash,
                existing.priorDeviceBindingCommitment == payload.deviceBindingCommitment
            else {
                throw OpenCsvAccountMaterialError.conflictingAccountRoot
            }
            return existing
        }
        guard
            let material = try accountMaterial(),
            material.isRestoredReadOnly,
            material.accountRoot == payload.accountRoot
        else {
            throw OpenCsvAccountMaterialError.conflictingAccountRoot
        }
        let binding = randomBytes(32)
        guard binding.count == 32 else {
            throw OpenCsvAccountMaterialError.invalidLength
        }
        var commitmentInput = Data("OpenCSV device binding v1".utf8)
        commitmentInput.append(payload.accountRoot)
        commitmentInput.append(binding)
        let commitment = SHA256.hash(data: commitmentInput)
            .map { String(format: "%02x", $0) }
            .joined()
        let pending = OpenCsvPendingTestDeviceRebind(
            sourceCheckpointHash: payload.checkpointHash,
            priorDeviceBindingCommitment: payload.deviceBindingCommitment,
            newDeviceBinding: binding,
            newDeviceBindingCommitment: commitment,
        )
        try setPendingTestDeviceRebind(pending)
        return pending
    }

    public func setPendingTestDeviceRebind(_ pending: OpenCsvPendingTestDeviceRebind) throws {
        let data = try JSONEncoder().encode(pending)
        try keychainStorage.setDataValue(
            data,
            service: Self.keychainService,
            key: Self.pendingTestDeviceRebindKey,
        )
    }

    /// Write the combined root+binding first, then remove the root-only key.
    /// A crash between those operations is harmless because reads prefer the
    /// combined record and both records name the same root.
    public func installReboundAccountMaterial(
        root: Data,
        binding: Data,
    ) throws {
        if let current = try accountMaterial(), !current.isRestoredReadOnly {
            guard current.accountRoot == root, current.deviceBinding == binding else {
                throw OpenCsvAccountMaterialError.conflictingAccountRoot
            }
            return
        }
        let material = try OpenCsvAccountMaterial(accountRoot: root, deviceBinding: binding)
        try keychainStorage.setDataValue(
            JSONEncoder().encode(material),
            service: Self.keychainService,
            key: Self.primaryAccountMaterialKey,
        )
        try keychainStorage.removeValue(
            service: Self.keychainService,
            key: Self.restoredAccountRootKey,
        )
    }

    public func finishTestDeviceRebind() throws {
        try keychainStorage.removeValue(
            service: Self.keychainService,
            key: Self.pendingTestDeviceRebindKey,
        )
    }
#endif

    // MARK: - Legacy wallet secrets (retained read-only for migration)

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

    // MARK: - Secure Backup handoff

    public func secureBackupPayload(tx: DBReadTransaction) throws -> OpenCsvSecureBackupPayload? {
        try keyValueStore.getCodableValue(forKey: Self.secureBackupPayloadKey, transaction: tx)
    }

    public func setSecureBackupPayload(_ payload: OpenCsvSecureBackupPayload, tx: DBWriteTransaction) throws {
        try keyValueStore.setCodable(payload, key: Self.secureBackupPayloadKey, transaction: tx)
    }

    /// Last successfully decoded wallet status for presentation only. This
    /// never authorizes a send or substitutes for Rust-owned wallet state;
    /// it lets the UI remain readable while network synchronization runs.
    public func walletPresentationSnapshotData(tx: DBReadTransaction) -> Data? {
        keyValueStore.getData(Self.walletPresentationSnapshotKey, transaction: tx)
    }

    public func setWalletPresentationSnapshotData(_ data: Data, tx: DBWriteTransaction) {
        keyValueStore.setData(data, key: Self.walletPresentationSnapshotKey, transaction: tx)
    }

    public func linkedWatchAccount(tx: DBReadTransaction) throws -> OpenCsvLinkedWatchAccount? {
        try keyValueStore.getCodableValue(forKey: Self.linkedWatchAccountKey, transaction: tx)
    }

    public func setLinkedWatchAccount(_ account: OpenCsvLinkedWatchAccount, tx: DBWriteTransaction) throws {
        try keyValueStore.setCodable(account, key: Self.linkedWatchAccountKey, transaction: tx)
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

    /// Generic Esplora read accelerator and transaction-relay fallback.
    /// This is not an OpenCSV service and is never authoritative for spend
    /// state; Rust verifies selected outpoints through compact-filter peers.
    public func esploraUrl(tx: DBReadTransaction) -> String {
        if let configured = keyValueStore.getString(Self.esploraUrlKey, transaction: tx), !configured.isEmpty {
            return configured
        }
        switch network(tx: tx) {
        case "mainnet":
            return "https://mempool.space/api"
        case "regtest":
            return "http://127.0.0.1:3002"
        default:
            return "https://mempool.space/signet/api"
        }
    }

    public func setEsploraUrl(_ urlString: String?, tx: DBWriteTransaction) {
        keyValueStore.setString(urlString?.trimmingCharacters(in: .whitespacesAndNewlines), key: Self.esploraUrlKey, transaction: tx)
    }

    // MARK: - Chain view settings (Chain Views v2)

    /// Indexers asked for the exclusion check.
    ///
    /// Several independent ones is the whole point: one can hide a
    /// double-spend, a quorum cannot unless all are compromised. The old
    /// single-anchor-server setting migrates in as one entry — honest, but
    /// note that one indexer is not a cross-check.
    public func indexerUrls(tx: DBReadTransaction) -> [String] {
        do {
            if
                let urls: [String] = try keyValueStore.getCodableValue(
                    forKey: Self.indexerUrlsKey,
                    transaction: tx,
                )
            {
                return urls
            }
        } catch {
            owsFailDebug("could not decode the OpenCSV indexer list: \(error)")
        }
        // Migration: a wallet configured before v2 has one anchor server.
        return anchorServerUrl(tx: tx).map { [$0.absoluteString] } ?? []
    }

    public func setIndexerUrls(_ urls: [String], tx: DBWriteTransaction) throws {
        try keyValueStore.setCodable(urls.filter { !$0.isEmpty }, key: Self.indexerUrlsKey, transaction: tx)
    }

    /// Bitcoin P2P peers for trustless SPV point verification. Empty means
    /// point verification is unavailable and only indexer answers remain.
    public func spvPeers(tx: DBReadTransaction) -> [String] {
        (try? keyValueStore.getCodableValue(forKey: Self.spvPeersKey, transaction: tx)) ?? []
    }

    public func setSpvPeers(_ peers: [String], tx: DBWriteTransaction) throws {
        try keyValueStore.setCodable(peers.filter { !$0.isEmpty }, key: Self.spvPeersKey, transaction: tx)
    }

    /// Where a fresh self-scan index starts walking filters — the wallet's
    /// birth height. A reviewed instrument set may provide a public lower
    /// bound; otherwise the conservative default is 1. Explicit user or
    /// recovery configuration always wins. Never 0: the FFI reserves height
    /// 0 as its mempool sentinel and rejects it.
    public func scanFromHeight(tx: DBReadTransaction) -> UInt64 {
        if
            let stored: UInt64 = try? keyValueStore.getCodableValue(
                forKey: Self.scanFromHeightKey,
                transaction: tx,
            )
        {
            return max(1, stored)
        }
        return OpenCsvReviewedUsdIssuers.earliestRelevantHeight(for: network(tx: tx)) ?? 1
    }

    public func setScanFromHeight(_ height: UInt64, tx: DBWriteTransaction) throws {
        try keyValueStore.setCodable(height, key: Self.scanFromHeightKey, transaction: tx)
    }

    public func network(tx: DBReadTransaction) -> String {
        keyValueStore.getString(Self.networkKey, transaction: tx) ?? "signet"
    }

    public func setNetwork(_ network: String, tx: DBWriteTransaction) {
        keyValueStore.setString(network, key: Self.networkKey, transaction: tx)
    }

    /// Persist only operator-selected modes. The check identity, endpoint,
    /// kind and built-in pin profile continue to come from the reviewed app
    /// binary, so a database edit cannot silently redirect a required check
    /// or replace its certificate profile.
    public func observationChecks(tx: DBReadTransaction) -> [OpenCsvObservationCheck] {
        let defaults = OpenCsvObservationCheck.defaults(for: network(tx: tx))
        let modes: [String: OpenCsvObservationMode] =
            (try? keyValueStore.getCodableValue(
                forKey: Self.observationModesKey,
                transaction: tx,
            )) ?? [:]
        return defaults.map { check in
            OpenCsvObservationCheck(
                id: check.id,
                kind: check.kind,
                endpoint: check.endpoint,
                mode: modes[check.id] ?? check.mode,
                pinProfile: check.pinProfile,
                chainFingerprintsSha256: check.chainFingerprintsSha256,
                maxAgeSeconds: check.maxAgeSeconds,
            )
        }
    }

    /// Returns false for an unknown check id. Callers must never create a
    /// new endpoint by typo or by accepting an unreviewed server string.
    @discardableResult
    public func setObservationMode(
        _ mode: OpenCsvObservationMode,
        checkId: String,
        tx: DBWriteTransaction,
    ) throws -> Bool {
        let knownIds = Set(OpenCsvObservationCheck.defaults(for: network(tx: tx)).map(\.id))
        guard knownIds.contains(checkId) else { return false }
        var modes: [String: OpenCsvObservationMode] =
            (try? keyValueStore.getCodableValue(
                forKey: Self.observationModesKey,
                transaction: tx,
            )) ?? [:]
        modes[checkId] = mode
        try keyValueStore.setCodable(modes, key: Self.observationModesKey, transaction: tx)
        return true
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
            if
                let consignmentId = keyValueStore.getString(
                    Self.attachmentConsignmentIdPrefix + "\(attachmentId)",
                    transaction: tx,
                )
            {
                return try keyValueStore.getCodableValue(
                    forKey: Self.canonicalVerdictKey(consignmentId),
                    transaction: tx,
                )
            }
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
        messageUniqueId: String? = nil,
        tx: DBWriteTransaction,
    ) {
        let verdictKey: String
        if let consignmentId = record.consignmentId {
            verdictKey = Self.canonicalVerdictKey(consignmentId)
            keyValueStore.setString(
                consignmentId,
                key: Self.attachmentConsignmentIdPrefix + "\(attachmentId)",
                transaction: tx,
            )
            let presentationId = record.paymentId ?? consignmentId
            let presentationKey = Self.canonicalPresentationAttachmentPrefix + presentationId
            let supersedesPrior = record.isVerified
                && record.supersededConsignmentIds?.isEmpty == false
            if
                supersedesPrior
                || keyValueStore.getString(presentationKey, transaction: tx) == nil
            {
                keyValueStore.setString("\(attachmentId)", key: presentationKey, transaction: tx)
            }
            if let messageUniqueId {
                let messageKey = Self.canonicalPresentationMessagePrefix + presentationId
                if
                    supersedesPrior
                    || keyValueStore.getString(messageKey, transaction: tx) == nil
                {
                    keyValueStore.setString(messageUniqueId, key: messageKey, transaction: tx)
                }
            }
            if supersedesPrior {
                let supersededIds = Set(record.supersededConsignmentIds ?? [])
                for supersededId in supersededIds {
                    keyValueStore.setString(
                        "\(attachmentId)",
                        key: Self.canonicalPresentationAttachmentPrefix + supersededId,
                        transaction: tx,
                    )
                    if let messageUniqueId {
                        keyValueStore.setString(
                            messageUniqueId,
                            key: Self.canonicalPresentationMessagePrefix + supersededId,
                            transaction: tx,
                        )
                    }
                }
                var activities = incomingActivities(tx: tx)
                activities.removeAll { activity in
                    guard
                        let activityConsignmentId = keyValueStore.getString(
                            Self.attachmentConsignmentIdPrefix + "\(activity.attachmentId)",
                            transaction: tx,
                        )
                    else {
                        return false
                    }
                    return supersededIds.contains(activityConsignmentId)
                }
                do {
                    try keyValueStore.setCodable(
                        activities,
                        key: Self.incomingActivitiesKey,
                        transaction: tx,
                    )
                } catch {
                    owsFailDebug("could not supersede OpenCSV incoming activity: \(error)")
                }
            }
        } else {
            // Compatibility only for prototype records produced before Rust
            // returned canonical identity.
            verdictKey = Self.verdictKey(attachmentId)
        }
        do {
            try keyValueStore.setCodable(record, key: verdictKey, transaction: tx)
        } catch {
            owsFailDebug("could not persist an OpenCSV verdict: \(error)")
        }
        guard record.isVerified, let blob else { return }
        let replayEntry = record.consignmentId.map { "c:\($0)" } ?? "a:\(attachmentId)"
        appendReplayEntry(replayEntry, blob: blob, tx: tx)
    }

    // MARK: - Incoming activity

    public func incomingActivities(tx: DBReadTransaction) -> [OpenCsvIncomingActivity] {
        do {
            return try keyValueStore.getCodableValue(
                forKey: Self.incomingActivitiesKey,
                transaction: tx,
            ) ?? []
        } catch {
            owsFailDebug("could not decode OpenCSV incoming activity: \(error)")
            return []
        }
    }

    public func verifiedChainView(tx: DBReadTransaction) -> OpenCsvVerifiedChainView? {
        do {
            return try keyValueStore.getCodableValue(
                forKey: Self.verifiedChainViewKey,
                transaction: tx,
            )
        } catch {
            owsFailDebug("could not decode OpenCSV verified chain-view receipt: \(error)")
            return nil
        }
    }

    public func setVerifiedChainView(
        _ receipt: OpenCsvVerifiedChainView,
        tx: DBWriteTransaction,
    ) throws {
        try keyValueStore.setCodable(receipt, key: Self.verifiedChainViewKey, transaction: tx)
    }

    /// Derive scheduling only from durable state. If iOS kills the process,
    /// the next task registration computes the same answer without relying on
    /// an in-memory timer or notification.
    public func backgroundWorkUrgency(tx: DBReadTransaction) -> OpenCsvBackgroundWorkUrgency {
        let pendingDelivery = pendingDeliveries(tx: tx).contains {
            $0.enqueuedAt != nil || !$0.hasExhaustedRetries
        }
        let pendingOperation = ((try? pendingAccountOperations(tx: tx)) ?? []).isEmpty == false
        return OpenCsvBackgroundWorkPolicy.urgency(
            activityStates: incomingActivities(tx: tx).map(\.state),
            hasPendingDelivery: pendingDelivery,
            hasPendingOperation: pendingOperation,
            hasInFlightSend: !inFlightSends(tx: tx).isEmpty,
        )
    }

    /// Persist one idempotent state transition. The list is bounded because
    /// it is wallet presentation history, not the protocol journal.
    public func upsertIncomingActivity(
        attachmentId: Attachment.IDType,
        threadUniqueId: String?,
        messageUniqueId: String?,
        state: OpenCsvIncomingActivityState,
        amount: UInt64? = nil,
        currency: String? = nil,
        detail: String? = nil,
        now: Date = Date(),
        tx: DBWriteTransaction,
    ) throws {
        var activities = incomingActivities(tx: tx)
        let existing = activities.first { $0.attachmentId == attachmentId }
        activities.removeAll { $0.attachmentId == attachmentId }
        // Amounts are ledger facts, not hints from an unverified envelope.
        // Never carry an earlier amount backward into a confirming row.
        let resolvedAmount: UInt64? = switch state {
        case .awaitingObservers, .availableUnconfirmed, .available, .settled:
            amount ?? existing?.amount
        case .confirming, .needsAttention:
            nil
        }
        activities.append(OpenCsvIncomingActivity(
            attachmentId: attachmentId,
            threadUniqueId: threadUniqueId ?? existing?.threadUniqueId,
            messageUniqueId: messageUniqueId ?? existing?.messageUniqueId,
            state: state,
            amount: resolvedAmount,
            currency: currency ?? existing?.currency,
            detail: detail,
            firstSeenAt: existing?.firstSeenAt ?? now,
            updatedAt: now,
        ))
        activities.sort { $0.firstSeenAt < $1.firstSeenAt }
        if activities.count > 100 {
            activities.removeFirst(activities.count - 100)
        }
        try keyValueStore.setCodable(
            activities,
            key: Self.incomingActivitiesKey,
            transaction: tx,
        )
    }

    public func removeIncomingActivity(
        attachmentId: Attachment.IDType,
        tx: DBWriteTransaction,
    ) throws {
        var activities = incomingActivities(tx: tx)
        activities.removeAll { $0.attachmentId == attachmentId }
        try keyValueStore.setCodable(
            activities,
            key: Self.incomingActivitiesKey,
            transaction: tx,
        )
    }

    /// Exactly one transport attachment renders as the logical payment for
    /// a canonical consignment. Byte-distinct retries remain available as
    /// ordinary files, but cannot create a second verified payment bubble.
    public func isCanonicalPresentationAttachment(
        attachmentId: Attachment.IDType,
        messageUniqueId: String? = nil,
        tx: DBReadTransaction,
    ) -> Bool {
        guard
            let consignmentId = keyValueStore.getString(
                Self.attachmentConsignmentIdPrefix + "\(attachmentId)",
                transaction: tx,
            )
        else {
            return true
        }
        let record: OpenCsvVerdictRecord? = try? keyValueStore.getCodableValue(
            forKey: Self.canonicalVerdictKey(consignmentId),
            transaction: tx,
        )
        let presentationId = record?.paymentId ?? consignmentId
        if
            let canonicalMessageId = keyValueStore.getString(
                Self.canonicalPresentationMessagePrefix + presentationId,
                transaction: tx,
            )
        {
            return messageUniqueId == canonicalMessageId
        }
        return keyValueStore.getString(
            Self.canonicalPresentationAttachmentPrefix + presentationId,
            transaction: tx,
        ) == "\(attachmentId)"
    }

    /// True once a Signal message has been committed for this logical
    /// consignment. Delivery uses this as its final transaction-local guard:
    /// a crash may leave several retry records, but it must never create a
    /// second payment message for the same canonical protocol object.
    public func hasCanonicalPresentation(
        consignmentId: String,
        tx: DBReadTransaction,
    ) -> Bool {
        let record: OpenCsvVerdictRecord? = try? keyValueStore.getCodableValue(
            forKey: Self.canonicalVerdictKey(consignmentId),
            transaction: tx,
        )
        let presentationId = record?.paymentId ?? consignmentId

        // `setVerdict` keys presentation identity by the stable payment id
        // when Rust provides one. Looking up only the consignment id misses
        // every such delivery after a restart and inserts the same outgoing
        // payment message again. Check both identities for compatibility
        // with records written before payment ids were introduced.
        return [presentationId, consignmentId].contains { candidate in
            keyValueStore.getString(
                Self.canonicalPresentationAttachmentPrefix + candidate,
                transaction: tx,
            ) != nil || keyValueStore.getString(
                Self.canonicalPresentationMessagePrefix + candidate,
                transaction: tx,
            ) != nil
        }
    }

    public func blobForAttachment(attachmentId: Attachment.IDType, tx: DBReadTransaction) -> Data? {
        if
            let consignmentId = keyValueStore.getString(
                Self.attachmentConsignmentIdPrefix + "\(attachmentId)",
                transaction: tx,
            )
        {
            return blob(forReplayEntry: "c:\(consignmentId)", tx: tx)
        }
        return blob(forReplayEntry: "a:\(attachmentId)", tx: tx)
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
        /// Rust operation kind. Optional only for prototype records written
        /// before the account-wallet migration.
        public let operationKind: String?
        /// Rust operation identity and idempotent delivery acknowledgement.
        /// Nil only for prototype deliveries created before the account API.
        public let operationId: String?
        public let deliveryNonce: String?
        /// Canonical Rust identity, independent of attachment transport bytes.
        public let consignmentId: String?
        /// Proof-protected logical payment identity, stable across RBF.
        public let paymentId: String?
        public let supersededConsignmentIds: [String]?
        /// Previous Bitcoin txid when this attachment replaces a consignment
        /// already sent for the same durable operation.
        public let replacesTxid: String?
        public let createdAt: Date
        /// Delivery attempts so far; at `maxDeliveryAttempts` automatic
        /// retries stop.
        public var attempts: Int
        /// Set atomically with insertion of the Signal message. The record
        /// remains until Rust acknowledges the matching operation/nonce, so
        /// a crash cannot cause either a duplicate chat message or a lost
        /// protocol delivery acknowledgement.
        public var enqueuedAt: Date?

        public var hasExhaustedRetries: Bool { attempts >= OpenCsvWalletStore.maxDeliveryAttempts }

        public init(
            id: String = UUID().uuidString,
            threadUniqueId: String,
            body: String,
            replayEntry: String,
            amount: UInt64,
            currency: String?,
            assetId: String?,
            operationKind: String? = nil,
            operationId: String? = nil,
            deliveryNonce: String? = nil,
            consignmentId: String? = nil,
            paymentId: String? = nil,
            supersededConsignmentIds: [String]? = nil,
            replacesTxid: String? = nil,
            createdAt: Date,
            attempts: Int = 0,
            enqueuedAt: Date? = nil,
        ) {
            self.id = id
            self.threadUniqueId = threadUniqueId
            self.body = body
            self.replayEntry = replayEntry
            self.amount = amount
            self.currency = currency
            self.assetId = assetId
            self.operationKind = operationKind
            self.operationId = operationId
            self.deliveryNonce = deliveryNonce
            self.consignmentId = consignmentId
            self.paymentId = paymentId
            self.supersededConsignmentIds = supersededConsignmentIds
            self.replacesTxid = replacesTxid
            self.createdAt = createdAt
            self.attempts = attempts
            self.enqueuedAt = enqueuedAt
        }
    }

    /// Signal delivery metadata for a Rust-durable operation whose signed
    /// transaction or consignment may need resuming after app restart.
    public struct PendingAccountOperation: Codable, Equatable {
        public let operationId: String
        public let threadUniqueId: String
        public let amount: UInt64
        public let currency: String?
        public let assetId: String?
        public let kind: String?
        public let createdAt: Date
        /// Rust-owned coalescing identity. Nil decodes legacy solo records.
        public let batchLocalId: String?
        public let batchDeadlineMs: Int64?
        public let batchOrdinal: UInt8?
        /// The Signal-authenticated, nonspendable intent message is inserted
        /// atomically with these fields. Optional for records written before
        /// background proving existed.
        public var announcementMessageId: String?
        public var announcementEnqueuedAt: Date?
        /// Stable Rust rejection reason awaiting one idempotent Signal
        /// follow-up. The record is removed in the same transaction that
        /// inserts that failure message.
        public var failureReason: String?

        public init(
            operationId: String,
            threadUniqueId: String,
            amount: UInt64,
            currency: String?,
            assetId: String?,
            kind: String? = nil,
            createdAt: Date,
            batchLocalId: String? = nil,
            batchDeadlineMs: Int64? = nil,
            batchOrdinal: UInt8? = nil,
            announcementMessageId: String? = nil,
            announcementEnqueuedAt: Date? = nil,
            failureReason: String? = nil,
        ) {
            self.operationId = operationId
            self.threadUniqueId = threadUniqueId
            self.amount = amount
            self.currency = currency
            self.assetId = assetId
            self.kind = kind
            self.createdAt = createdAt
            self.batchLocalId = batchLocalId
            self.batchDeadlineMs = batchDeadlineMs
            self.batchOrdinal = batchOrdinal
            self.announcementMessageId = announcementMessageId
            self.announcementEnqueuedAt = announcementEnqueuedAt
            self.failureReason = failureReason
        }
    }

    public func pendingAccountOperations(tx: DBReadTransaction) throws -> [PendingAccountOperation] {
        try keyValueStore.getCodableValue(forKey: Self.pendingAccountOperationsKey, transaction: tx) ?? []
    }

    public func upsertPendingAccountOperation(
        _ operation: PendingAccountOperation,
        tx: DBWriteTransaction,
    ) throws {
        var operations = try pendingAccountOperations(tx: tx)
        operations.removeAll { $0.operationId == operation.operationId }
        operations.append(operation)
        try keyValueStore.setCodable(
            operations,
            key: Self.pendingAccountOperationsKey,
            transaction: tx,
        )
    }

    public func removePendingAccountOperation(operationId: String, tx: DBWriteTransaction) throws {
        var operations = try pendingAccountOperations(tx: tx)
        operations.removeAll { $0.operationId == operationId }
        try keyValueStore.setCodable(
            operations,
            key: Self.pendingAccountOperationsKey,
            transaction: tx,
        )
    }

    public func removePendingAccountOperations(batchLocalId: String, tx: DBWriteTransaction) throws {
        var operations = try pendingAccountOperations(tx: tx)
        operations.removeAll { $0.batchLocalId == batchLocalId }
        try keyValueStore.setCodable(
            operations,
            key: Self.pendingAccountOperationsKey,
            transaction: tx,
        )
    }

    public func markPendingAccountOperationAnnounced(
        operationId: String,
        messageId: String,
        tx: DBWriteTransaction,
    ) throws {
        var operations = try pendingAccountOperations(tx: tx)
        guard let index = operations.firstIndex(where: { $0.operationId == operationId }) else {
            return
        }
        operations[index].announcementMessageId = messageId
        operations[index].announcementEnqueuedAt = operations[index].announcementEnqueuedAt ?? Date()
        try keyValueStore.setCodable(
            operations,
            key: Self.pendingAccountOperationsKey,
            transaction: tx,
        )
    }

    public func markPendingAccountOperationFailed(
        operationId: String,
        reason: String,
        tx: DBWriteTransaction,
    ) throws {
        var operations = try pendingAccountOperations(tx: tx)
        guard let index = operations.firstIndex(where: { $0.operationId == operationId }) else {
            return
        }
        operations[index].failureReason = reason
        try keyValueStore.setCodable(
            operations,
            key: Self.pendingAccountOperationsKey,
            transaction: tx,
        )
    }

    /// Every undelivered consignment, oldest first.
    ///
    /// A decode failure drops that one record from the result and is
    /// reported — it must never be allowed to look like "the queue is
    /// empty", which would silently strand every queued payment.
    public func pendingDeliveries(tx: DBReadTransaction) -> [PendingDelivery] {
        pendingDeliveryIds(tx: tx).compactMap { id in
            do {
                guard
                    let delivery: PendingDelivery = try keyValueStore.getCodableValue(
                        forKey: Self.pendingDeliveryKey(id),
                        transaction: tx,
                    )
                else {
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

    /// Insert an exact consignment delivery once. Actor reentrancy and process
    /// relaunch may reconstruct the same ready object, while RBF intentionally
    /// creates a different consignment for the same operation.
    public func addPendingDelivery(
        _ delivery: PendingDelivery,
        tx: DBWriteTransaction,
    ) throws {
        if
            let operationId = delivery.operationId, pendingDeliveries(tx: tx).contains(where: {
                $0.operationId == operationId && $0.consignmentId == delivery.consignmentId
            })
        {
            return
        }
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

    public func markPendingDeliveryEnqueued(id: String, tx: DBWriteTransaction) throws {
        guard
            var delivery: PendingDelivery = try keyValueStore.getCodableValue(
                forKey: Self.pendingDeliveryKey(id),
                transaction: tx,
            )
        else {
            return
        }
        delivery.enqueuedAt = delivery.enqueuedAt ?? Date()
        try keyValueStore.setCodable(delivery, key: Self.pendingDeliveryKey(id), transaction: tx)
    }

    private func pendingDeliveryIds(tx: DBReadTransaction) -> [String] {
        do {
            return try keyValueStore.getCodableValue(forKey: Self.pendingDeliveriesKey, transaction: tx) ?? []
        } catch {
            owsFailDebug("could not decode the pending OpenCSV delivery index: \(error)")
            return []
        }
    }

    // MARK: - In-flight sends

    /// A transfer that has been proved but whose anchor has not yet been
    /// finalized into a consignment.
    ///
    /// Proving produces coin openings with fresh randomness that cannot be
    /// re-derived, and they live only in the FFI wallet's memory. Without
    /// this record, a crash between broadcasting the anchor and finalizing
    /// loses the payment outright: the coins are spent on-chain and nothing
    /// can rebuild the consignment the recipient needs.
    ///
    /// `exportJson` is sensitive — it reveals coin values and owners — and
    /// is only ever written to the encrypted database.
    public struct InFlightSend: Codable, Equatable {
        public let id: String
        public let exportJson: String
        /// Set once the anchor transaction has been broadcast. Nil means
        /// nothing was published, so the record can simply be dropped.
        public var txidHex: String?
        public var height: UInt64?
        public var position: UInt32?
        public let threadUniqueId: String
        public let amount: UInt64
        public let currency: String?
        public let assetId: String?
        public let createdAt: Date

        public init(
            id: String = UUID().uuidString,
            exportJson: String,
            txidHex: String? = nil,
            height: UInt64? = nil,
            position: UInt32? = nil,
            threadUniqueId: String,
            amount: UInt64,
            currency: String?,
            assetId: String?,
            createdAt: Date,
        ) {
            self.id = id
            self.exportJson = exportJson
            self.txidHex = txidHex
            self.height = height
            self.position = position
            self.threadUniqueId = threadUniqueId
            self.amount = amount
            self.currency = currency
            self.assetId = assetId
            self.createdAt = createdAt
        }
    }

    public func inFlightSends(tx: DBReadTransaction) -> [InFlightSend] {
        do {
            return try keyValueStore.getCodableValue(forKey: Self.inFlightSendsKey, transaction: tx) ?? []
        } catch {
            owsFailDebug("could not decode in-flight OpenCSV sends: \(error)")
            return []
        }
    }

    public func upsertInFlightSend(_ send: InFlightSend, tx: DBWriteTransaction) throws {
        var sends = inFlightSends(tx: tx)
        sends.removeAll { $0.id == send.id }
        sends.append(send)
        try keyValueStore.setCodable(sends, key: Self.inFlightSendsKey, transaction: tx)
    }

    public func removeInFlightSend(id: String, tx: DBWriteTransaction) throws {
        var sends = inFlightSends(tx: tx)
        sends.removeAll { $0.id == id }
        try keyValueStore.setCodable(sends, key: Self.inFlightSendsKey, transaction: tx)
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

    private static func canonicalVerdictKey(_ consignmentId: String) -> String {
        "verdict:consignment:\(consignmentId)"
    }

    private static func pendingDeliveryKey(_ id: String) -> String {
        "pendingDelivery:\(id)"
    }

    private static func blobKey(_ entry: String) -> String {
        "blob:\(entry)"
    }
}
