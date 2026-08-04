//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import OpenCsvFFI

/// Errors surfaced by the OpenCSV FFI boundary.
public enum OpenCsvClientError: Error, Equatable {
    /// The Rust side reported a failure (`{"error": ...}`).
    case ffi(String)
    /// The FFI returned JSON we could not decode.
    case decode(String)
}

/// One credited (or held) asset total, as reported by the wallet.
public struct OpenCsvCredit: Codable, Equatable {
    public let assetId: String
    public let currency: String?
    public let amount: UInt64
}

/// Versioned issuer-backed instrument terms committed by asset genesis.
public struct OpenCsvInstrumentTerms: Codable, Equatable {
    public let version: UInt32
    public let network: String
    public let displayName: String
    public let unitCode: String
    public let decimals: UInt8
    public let issuerName: String
    public let termsUri: String
    public let redemptionSummary: String
    public let testOnly: Bool

    public init(
        version: UInt32 = 1,
        network: String,
        displayName: String,
        unitCode: String,
        decimals: UInt8,
        issuerName: String,
        termsUri: String,
        redemptionSummary: String,
        testOnly: Bool,
    ) {
        self.version = version
        self.network = network
        self.displayName = displayName
        self.unitCode = unitCode
        self.decimals = decimals
        self.issuerName = issuerName
        self.termsUri = termsUri
        self.redemptionSummary = redemptionSummary
        self.testOnly = testOnly
    }
}

public struct OpenCsvInstrumentManifest: Codable, Equatable {
    public struct Genesis: Codable, Equatable {
        public let issuerPk: [UInt8]
        public let currencyCode: [UInt8]
        public let termsHash: [UInt8]
        public let nonce: UInt64

        public init(
            issuerPk: [UInt8],
            currencyCode: [UInt8],
            termsHash: [UInt8],
            nonce: UInt64,
        ) {
            self.issuerPk = issuerPk
            self.currencyCode = currencyCode
            self.termsHash = termsHash
            self.nonce = nonce
        }
    }

    public let terms: OpenCsvInstrumentTerms
    public let genesis: Genesis

    public init(terms: OpenCsvInstrumentTerms, genesis: Genesis) {
        self.terms = terms
        self.genesis = genesis
    }
}

/// One issuer-specific instrument admitted under Signal's single USD
/// product. The manifest is public; issuer signing material never enters
/// Signal. Lower priorities are preferred when one issuer can cover a send.
public struct OpenCsvUsdIssuerPolicy: Codable, Equatable {
    public let manifest: OpenCsvInstrumentManifest
    public let priority: UInt32

    public init(manifest: OpenCsvInstrumentManifest, priority: UInt32 = 0) {
        self.manifest = manifest
        self.priority = priority
    }
}

/// Exact instrument identity and local trust classification. Proof validity
/// never upgrades `trustState`; that is a separate recipient decision.
public struct OpenCsvInstrumentRecord: Codable, Equatable {
    public let assetId: String
    public let trustState: String
    /// Wallet product policy, assigned by Rust from the exact committed
    /// manifest. Swift never infers identity from the `USD` display code.
    public let profile: String
    public let issuerPriority: UInt32?
    public let manifest: OpenCsvInstrumentManifest?
}

/// Exact decimal conversion for Signal's USD product. The protocol stores
/// six-decimal base units; UI code never uses floating point.
public enum OpenCsvUsdAmount {
    public static let baseUnitsPerUnit: UInt64 = 1_000_000

    public static func parse(_ rawValue: String) -> UInt64? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = UInt64(parts[0]) else { return nil }
        let fractionText = parts.count == 2 ? String(parts[1]) : ""
        guard
            parts.count == 1 || !fractionText.isEmpty,
            fractionText.count <= 6,
            fractionText.utf8.allSatisfy({ (48...57).contains($0) })
        else { return nil }
        let paddedFraction = fractionText.padding(toLength: 6, withPad: "0", startingAt: 0)
        guard let fraction = UInt64(paddedFraction) else { return nil }
        let (scaledWhole, overflow) = whole.multipliedReportingOverflow(by: baseUnitsPerUnit)
        guard !overflow else { return nil }
        let (baseUnits, additionOverflow) = scaledWhole.addingReportingOverflow(fraction)
        return additionOverflow ? nil : baseUnits
    }

    public static func format(_ baseUnits: UInt64) -> String {
        let whole = baseUnits / baseUnitsPerUnit
        let fraction = String(format: "%06llu", baseUnits % baseUnitsPerUnit)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return fraction.isEmpty ? "\(whole)" : "\(whole).\(fraction)"
    }
}

/// One coin held by the wallet.
public struct OpenCsvCoin: Codable, Equatable {
    public let id: String
    public let assetId: String
    public let currency: String?
    public let value: UInt64
    public let unspent: Bool
}

/// Verification outcome for a received consignment.
public struct OpenCsvVerdict: Codable, Equatable {
    public struct Anchor: Codable, Equatable {
        public let height: UInt64
        public let position: UInt32
    }

    public let status: String
    public let reason: String?
    public let credits: [OpenCsvCredit]?
    public let coins: [OpenCsvCoin]?
    public let anchor: Anchor?
    /// Stable identity over Rust's canonical consignment encoding. Signal
    /// keys verdict and rendered-cell state by this value, never by an
    /// attachment id or delivery-attempt nonce.
    public let consignmentId: String?
    /// Which chain view decided this verdict ("self-scan", "cross-check",
    /// "single-snapshot"). Set by the receive pipeline, never by the FFI;
    /// nil on verdicts that predate the distinction.
    public var chainView: String?

    public var isVerified: Bool { status == "verified" }

    public init(
        status: String,
        reason: String?,
        credits: [OpenCsvCredit]?,
        coins: [OpenCsvCoin]?,
        anchor: Anchor?,
        consignmentId: String? = nil,
    ) {
        self.status = status
        self.reason = reason
        self.credits = credits
        self.coins = coins
        self.anchor = anchor
        self.consignmentId = consignmentId
    }
}

// MARK: - Signal-native account wallet

public enum OpenCsvAccountRole: String, Codable, Equatable {
    case primary
    case linked
}

/// Public policy supplied when opening the Rust-owned account wallet. Secret
/// keys, Bitcoin inputs, change addresses and transaction bytes are
/// intentionally absent.
public struct OpenCsvAccountConfig: Codable, Equatable {
    public let version: UInt32
    public let network: String
    public let esploraUrl: String
    public let peers: [String]
    public let verificationPeers: [String]
    public let verificationTimeoutSecs: UInt64
    public let maxVerificationBlocks: UInt64
    public let role: OpenCsvAccountRole
    public let backupVerified: Bool
    public let expectedDeviceBindingCommitment: String?
    public let requiredConfirmations: UInt32
    public let stopGap: UInt
    public let parallelRequests: UInt
    public let watchExternalDescriptor: String?
    public let watchInternalDescriptor: String?
    public let watchOwner: String?
    /// Reviewed, public issuer manifests admitted under the single USD
    /// product. App review/configuration is the current trust root; this
    /// never contains issuer secrets or enables issuance.
    public let usdIssuers: [OpenCsvUsdIssuerPolicy]

    public init(
        version: UInt32 = 1,
        network: String,
        esploraUrl: String,
        peers: [String],
        verificationPeers: [String],
        verificationTimeoutSecs: UInt64 = 180,
        maxVerificationBlocks: UInt64 = 2_048,
        role: OpenCsvAccountRole,
        backupVerified: Bool,
        expectedDeviceBindingCommitment: String? = nil,
        requiredConfirmations: UInt32 = 6,
        stopGap: UInt = 20,
        parallelRequests: UInt = 4,
        watchExternalDescriptor: String? = nil,
        watchInternalDescriptor: String? = nil,
        watchOwner: String? = nil,
        usdIssuers: [OpenCsvUsdIssuerPolicy] = [],
    ) {
        self.version = version
        self.network = network
        self.esploraUrl = esploraUrl
        self.peers = peers
        self.verificationPeers = verificationPeers
        self.verificationTimeoutSecs = verificationTimeoutSecs
        self.maxVerificationBlocks = maxVerificationBlocks
        self.role = role
        self.backupVerified = backupVerified
        self.expectedDeviceBindingCommitment = expectedDeviceBindingCommitment
        self.requiredConfirmations = requiredConfirmations
        self.stopGap = stopGap
        self.parallelRequests = parallelRequests
        self.watchExternalDescriptor = watchExternalDescriptor
        self.watchInternalDescriptor = watchInternalDescriptor
        self.watchOwner = watchOwner
        self.usdIssuers = usdIssuers
    }
}

public struct OpenCsvAccountStatus: Codable, Equatable {
    public struct FeeReserve: Codable, Equatable {
        public struct Utxo: Codable, Equatable {
            public let txid: String
            public let vout: UInt32
            public let valueSats: UInt64
            public let keychain: String
            public let derivationIndex: UInt32
            public let reserved: Bool
        }

        public let confirmedSats: UInt64
        public let trustedPendingSats: UInt64
        public let untrustedPendingSats: UInt64
        public let immatureSats: UInt64
        public let totalSats: UInt64
        public let utxos: [Utxo]
    }

    public struct WatchDescriptors: Codable, Equatable {
        public let external: String
        public let `internal`: String
    }

    public struct DeviceBinding: Codable, Equatable {
        public let status: String
        public let commitment: String?
    }

    public struct SyncProvenance: Codable, Equatable {
        public let accelerator: String
        public let authoritative: String
        public let verificationPeerCount: UInt
        public let lastSyncAt: String?
        public let lastSyncTip: String?
    }

    public let version: UInt32
    public let role: OpenCsvAccountRole
    public let network: String
    public let owners: [String]
    public let assets: [OpenCsvCredit]
    public let instruments: [OpenCsvInstrumentRecord]
    public let feeReserve: FeeReserve
    public let depositAddress: String
    public let watchDescriptors: WatchDescriptors
    public let backupVerified: Bool
    public let writeEnabled: Bool
    /// Always false for Signal's owner-only wallet boundary.
    public let issuanceEnabled: Bool
    public let deviceBinding: DeviceBinding
    public let syncProvenance: SyncProvenance
    public let rootFingerprint: String
}

public struct OpenCsvAccountSyncReport: Codable, Equatable {
    public let status: String
    public let tipHeight: UInt64
    public let feeReserveSats: UInt64
    public let source: String
    public let authoritativeSpendCheck: String
}

public struct OpenCsvPreparedOperation: Codable, Equatable {
    public let operationId: String
    public let state: String
    public let fundingOutpoint: String
    public let fundingValueSats: UInt64
    public let anchorRecordHex: String
    public let assetId: String?
    public let toOwner: String?
    public let checkpointHash: String
    public let backupAckRequired: Bool
}

public struct OpenCsvAccountOperation: Codable, Equatable {
    public struct Receipt: Codable, Equatable {
        public let txid: String?
        public let feeSats: UInt64?
        public let feeRateSatPerVb: UInt64?
        public let deliveryNonce: String?
        public let consignmentId: String?
        public let consignmentBase64: String?
        public let deliveryReady: Bool?
        public let replaces: String?
        public let feeIncrementSats: UInt64?
        public let replacementChangeSats: UInt64?
    }

    public let operationId: String
    public let kind: String
    public let state: String
    public let txid: String?
    public let receipt: Receipt?
    public let rejectionReason: String?
    public let deliveryNonce: String
    public let checkpointHash: String?
    public let backupAcked: Bool
}

/// Public, non-secret operation metadata exported in the compact account
/// checkpoint. The wallet UI uses this list to offer RBF only for
/// transactions that Rust itself created.
public struct OpenCsvAccountOperationSummary: Codable, Equatable {
    public let operationId: String
    public let kind: String
    public let state: String
    public let txid: String?
}

public struct OpenCsvAccountCheckpoint: Codable, Equatable {
    public struct Payload: Codable, Equatable {
        public let version: UInt32
        public let network: String
        public let rootFingerprint: String
        public let deviceBindingCommitment: String?
        public let owners: [String]
    }

    public let checkpoint: Payload
    public let checkpointHash: String
}

/// A process-local handle to the durable Rust-owned account wallet. Callers
/// must serialize it; `OpenCsvPayments` owns one instance inside its actor.
public final class OpenCsvAccountWallet {
    private let handle: UInt64
    var rawHandle: UInt64 { handle }

    private struct Opened: Codable {
        let handle: UInt64
    }

    private struct BackupState: Codable {
        let backupVerified: Bool
        let writeEnabled: Bool
    }

    private struct BackupAcknowledgement: Codable {
        let operationId: String
        let backupAcked: Bool
        let checkpointHash: String
    }

    private struct Ok: Codable {
        let ok: Bool
    }

    public init(
        config: OpenCsvAccountConfig,
        accountRoot: Data,
        deviceBinding: Data?,
        databasePath: String,
    ) throws {
        guard accountRoot.isEmpty || accountRoot.count == 32 else {
            throw OpenCsvClientError.ffi("account root must be exactly 32 bytes")
        }
        guard deviceBinding == nil || deviceBinding?.count == 32 else {
            throw OpenCsvClientError.ffi("device binding must be exactly 32 bytes")
        }
        let configJson = try Self.encodeJson(config)
        let binding = deviceBinding ?? Data()
        let opened: Opened = try accountRoot.withUnsafeBytes { accountBytes in
            try binding.withUnsafeBytes { bindingBytes in
                try configJson.withCString { configPointer in
                    try databasePath.withCString { pathPointer in
                        try Self.take(opencsv_account_open(
                            configPointer,
                            accountBytes.bindMemory(to: UInt8.self).baseAddress,
                            accountRoot.count,
                            bindingBytes.bindMemory(to: UInt8.self).baseAddress,
                            binding.count,
                            pathPointer,
                        ))
                    }
                }
            }
        }
        self.handle = opened.handle
    }

    deinit {
        opencsv_string_free(opencsv_account_close(handle))
    }

    public func status() throws -> OpenCsvAccountStatus {
        try Self.take(opencsv_account_status(handle))
    }

    public func sync() throws -> OpenCsvAccountSyncReport {
        try Self.take(opencsv_account_sync(handle))
    }

    public func setBackupState(verified: Bool, checkpointVersion: UInt32) throws -> Bool {
        let state: BackupState = try Self.take(opencsv_account_set_backup_state(
            handle,
            verified,
            checkpointVersion,
        ))
        return state.writeEnabled
    }

    public func checkpoint() throws -> OpenCsvAccountCheckpoint {
        try Self.decode(checkpointJson())
    }

    /// Exact FFI response retained for Secure Backup. Re-encoding the
    /// summary type would discard asset, operation and consignment fields.
    public func checkpointJson() throws -> String {
        try Self.takeRaw(opencsv_account_checkpoint(handle))
    }

    public func operationSummaries() throws -> [OpenCsvAccountOperationSummary] {
        struct Envelope: Decodable {
            struct Checkpoint: Decodable {
                let operations: [OpenCsvAccountOperationSummary]
            }
            let checkpoint: Checkpoint
        }
        let envelope: Envelope = try Self.decode(checkpointJson())
        return envelope.checkpoint.operations
    }

    /// Import an exact Signal Secure Backup checkpoint into a clean account.
    /// Rust validates its hash, network, root-derived owner, and public
    /// device-binding commitment; a root-only restore remains read-only.
    public func restoreCheckpoint(_ checkpointJson: String) throws -> OpenCsvAccountStatus {
        try checkpointJson.withCString {
            try Self.take(opencsv_account_restore_checkpoint(handle, $0))
        }
    }

    public func verify(blob: Data, snapshotJson: String) throws -> OpenCsvVerdict {
        guard !blob.isEmpty else {
            throw OpenCsvClientError.ffi("consignment is empty")
        }
        return try blob.withUnsafeBytes { bytes in
            try snapshotJson.withCString { snapshot in
                try Self.take(opencsv_account_verify_consignment(
                    handle,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    blob.count,
                    snapshot,
                ))
            }
        }
    }

    public func prepareTransfer(assetId: String, toOwner: String, amount: UInt64) throws -> OpenCsvPreparedOperation {
        struct Request: Codable {
            let assetId: String
            let toOwner: String
            let amount: UInt64
        }
        return try callJson(
            Request(assetId: assetId, toOwner: toOwner, amount: amount),
            opencsv_transfer_prepare,
        )
    }

    public func acknowledgeBackup(operationId: String, checkpointHash: String) throws {
        let acknowledgement: BackupAcknowledgement = try operationId.withCString { operation in
            try checkpointHash.withCString { checkpoint in
                try Self.take(opencsv_operation_ack_backup(handle, operation, checkpoint))
            }
        }
        guard acknowledgement.backupAcked, acknowledgement.operationId == operationId else {
            throw OpenCsvClientError.decode("backup acknowledgement did not match the operation")
        }
    }

    public func signAndBroadcast(
        operationId: String,
        targetSatPerVb: UInt64,
        maxFeeSats: UInt64? = nil,
    ) throws -> OpenCsvAccountOperation {
        struct FeePolicy: Codable {
            let targetSatPerVb: UInt64
            let maxFeeSats: UInt64?
        }
        let policy = try Self.encodeJson(FeePolicy(targetSatPerVb: targetSatPerVb, maxFeeSats: maxFeeSats))
        return try operationId.withCString { operation in
            try policy.withCString { policyPointer in
                try Self.take(opencsv_operation_sign_and_broadcast(handle, operation, policyPointer))
            }
        }
    }

    public func operationStatus(_ operationId: String) throws -> OpenCsvAccountOperation {
        try operationId.withCString { try Self.take(opencsv_operation_status(handle, $0)) }
    }

    public func resume(_ operationId: String) throws -> OpenCsvAccountOperation {
        try operationId.withCString { try Self.take(opencsv_operation_resume(handle, $0)) }
    }

    public func cancel(_ operationId: String) throws {
        let result: Ok = try operationId.withCString { try Self.take(opencsv_operation_cancel(handle, $0)) }
        guard result.ok else {
            throw OpenCsvClientError.decode("cancel did not return success")
        }
    }

    public func feeBump(operationId: String, targetSatPerVb: UInt64) throws -> OpenCsvAccountOperation {
        try operationId.withCString {
            try Self.take(opencsv_fee_bump(handle, $0, targetSatPerVb))
        }
    }

    public func markDelivered(operationId: String, deliveryNonce: String) throws -> OpenCsvAccountOperation {
        try operationId.withCString { operation in
            try deliveryNonce.withCString { nonce in
                try Self.take(opencsv_operation_mark_delivered(handle, operation, nonce))
            }
        }
    }

    private func callJson<Request: Encodable, Reply: Decodable>(
        _ request: Request,
        _ function: (UInt64, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
    ) throws -> Reply {
        let json = try Self.encodeJson(request)
        return try json.withCString { try Self.take(function(handle, $0)) }
    }

    private static func take<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?) throws -> T {
        try decode(takeRaw(pointer))
    }

    private static func decode<T: Decodable>(_ raw: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: Data(raw.utf8))
        } catch {
            throw OpenCsvClientError.decode("\(error): \(raw.prefix(300))")
        }
    }

    private static func takeRaw(_ pointer: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let pointer else {
            throw OpenCsvClientError.ffi("FFI returned null")
        }
        defer { opencsv_string_free(pointer) }
        let raw = String(cString: pointer)
        struct FfiFailure: Codable {
            let error: String
        }
        if let failure = try? JSONDecoder().decode(FfiFailure.self, from: Data(raw.utf8)) {
            throw OpenCsvClientError.ffi(failure.error)
        }
        return raw
    }

    private static func encodeJson<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let json = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw OpenCsvClientError.decode("could not encode request")
        }
        return json
    }
}

/// Result of a legacy prototype `prove*` call. New account-wallet writes
/// reserve the Bitcoin funding input in Rust before proof generation.
public struct OpenCsvProved: Codable, Equatable {
    public let pendingId: UInt64
    public let anchorRecordHex: String
    public let ctxHex: String
    public let spends: [String]
}

/// Where a published anchor record landed on Bitcoin. Retained only for
/// importing prototype-era pending operations.
public struct OpenCsvAnchorRef: Codable, Equatable {
    public let txid: String
    public let height: UInt64
    public let position: UInt32

    public init(txid: String, height: UInt64, position: UInt32) {
        self.txid = txid
        self.height = height
        self.position = position
    }
}

/// A handle to an in-memory OpenCSV wallet (Rust side owns all key material
/// use). Not thread-safe: callers serialize access (see `OpenCsvPayments`).
public final class OpenCsvWallet {
    private let handle: UInt64
    /// For chain-view calls that take the wallet handle directly.
    var rawHandle: UInt64 { handle }
    public let owners: [String]

    private struct Opened: Codable {
        let handle: UInt64
        let owners: [String]
    }

    private struct Finalized: Codable {
        let consignmentBase64: String
        let spends: [String]
    }

    private struct Balances: Codable {
        let balances: [OpenCsvCredit]
    }

    private struct Status: Codable {
        let owners: [String]
        let coins: [OpenCsvCoin]
        let balances: [OpenCsvCredit]
    }

    private struct AssetId: Codable {
        let assetId: String
    }

    private struct Supply: Codable {
        let supply: UInt64
    }

    /// Create a fresh wallet, returning its secrets JSON for the Keychain.
    public static func createSecrets() throws -> String {
        let raw = try Self.takeRaw(opencsv_wallet_create())
        // Round-trips through the error check; the secrets JSON itself is
        // opaque to Swift.
        return raw
    }

    /// Open a wallet from persisted secrets JSON.
    public init(secretsJson: String) throws {
        let opened: Opened = try Self.take(secretsJson.withCString { opencsv_wallet_open($0) })
        self.handle = opened.handle
        self.owners = opened.owners
    }

    deinit {
        opencsv_string_free(opencsv_wallet_close(handle))
    }

    /// The wallet's current secrets JSON (persist after key/issuer changes).
    public func secretsJson() throws -> String {
        try Self.takeRaw(opencsv_wallet_secrets(handle))
    }

    /// Verify a received consignment blob against an anchor snapshot; on
    /// success the credited coins are stored in this wallet.
    public func verify(blob: Data, snapshotJson: String, requiredConfirmations: UInt64) throws -> OpenCsvVerdict {
        // An empty Data yields a null baseAddress; the C ABI treats null as
        // an error, but never rely on the caller's luck for that.
        guard !blob.isEmpty else {
            throw OpenCsvClientError.ffi("consignment is empty")
        }
        return try Self.take(blob.withUnsafeBytes { bytes in
            snapshotJson.withCString { snapshot in
                opencsv_verify_consignment(
                    handle,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    blob.count,
                    snapshot,
                    requiredConfirmations,
                )
            }
        })
    }

    /// Prove a transfer of `amounts` (`[pay]` or `[pay, change]`; change
    /// returns to this wallet) spending exactly two coins.
    public func proveTransfer(coinIds: [String], toOwnerHex: String, amounts: [UInt64]) throws -> OpenCsvProved {
        let ids = try Self.encodeJson(coinIds)
        let amountsJson = try Self.encodeJson(amounts)
        return try Self.take(ids.withCString { ids in
            toOwnerHex.withCString { owner in
                amountsJson.withCString { amounts in
                    opencsv_prove_transfer(handle, ids, owner, amounts)
                }
            }
        })
    }


    /// Export a proved-but-unanchored transaction so it survives process
    /// death.
    ///
    /// The export contains the coin openings, including randomness that
    /// cannot be re-derived — it is the only thing that can rebuild this
    /// payment after a crash, and it reveals coin values and owners, so it
    /// belongs only in the encrypted database.
    public func exportPending(pendingId: UInt64) throws -> String {
        struct Exported: Codable { let pendingJson: String }
        let exported: Exported = try Self.take(opencsv_pending_export(handle, pendingId))
        return exported.pendingJson
    }

    /// Re-import a pending transaction exported in an earlier process
    /// lifetime. Returns a fresh pending id; the original is not preserved.
    public func importPending(json: String) throws -> UInt64 {
        struct Imported: Codable { let pendingId: UInt64 }
        let imported: Imported = try Self.take(json.withCString { opencsv_pending_import(handle, $0) })
        return imported.pendingId
    }

    /// Rebuild a pending transaction's anchor record under a context the
    /// anchoring service reserved, without re-proving. Throws if that
    /// context would make the record misparse — reserve another and retry.
    public func rebind(pendingId: UInt64, ctxHex: String) throws -> String {
        struct Rebound: Codable { let anchorRecordHex: String }
        let rebound: Rebound = try Self.take(ctxHex.withCString {
            opencsv_pending_rebind(handle, pendingId, $0)
        })
        return rebound.anchorRecordHex
    }

    /// Build the consignment blob once the anchor record has been published.
    /// Marks the consumed coins spent; persist `spends` for replay.
    public func finalize(pendingId: UInt64, anchorRef: OpenCsvAnchorRef) throws -> (blob: Data, spends: [String]) {
        let refJson = try Self.encodeJson(anchorRef)
        let finalized: Finalized = try Self.take(refJson.withCString {
            opencsv_consignment_finalize(handle, pendingId, $0)
        })
        guard let blob = Data(base64Encoded: finalized.consignmentBase64) else {
            throw OpenCsvClientError.decode("finalize returned invalid base64")
        }
        return (blob, finalized.spends)
    }

    /// Replay persisted spend state after re-opening the wallet.
    public func markSpent(coinIds: [String]) throws {
        let ids = try Self.encodeJson(coinIds)
        struct Ok: Codable { let ok: Bool }
        let _: Ok = try Self.take(ids.withCString { opencsv_wallet_mark_spent(handle, $0) })
    }

    /// Unspent balances per asset.
    public func balance() throws -> [OpenCsvCredit] {
        let balances: Balances = try Self.take(opencsv_balance(handle))
        return balances.balances
    }

    /// Owners, coins, and balances in one call.
    public func coins() throws -> [OpenCsvCoin] {
        let status: Status = try Self.take(opencsv_wallet_status(handle))
        return status.coins
    }


    /// Public supply of an asset at the snapshot tip (needs no wallet).
    public static func audit(assetIdHex: String, snapshotJson: String) throws -> UInt64 {
        let supply: Supply = try take(assetIdHex.withCString { asset in
            snapshotJson.withCString { snapshot in
                opencsv_audit(asset, snapshot)
            }
        })
        return supply.supply
    }

    // MARK: - FFI plumbing

    /// Take ownership of a returned C string, surface `{"error":...}`, and
    /// decode the payload.
    private static func take<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?) throws -> T {
        let raw = try takeRaw(pointer)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: Data(raw.utf8))
        } catch {
            throw OpenCsvClientError.decode("\(error): \(raw.prefix(200))")
        }
    }

    private static func takeRaw(_ pointer: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let pointer else {
            throw OpenCsvClientError.ffi("FFI returned null")
        }
        defer { opencsv_string_free(pointer) }
        let raw = String(cString: pointer)
        struct FfiFailure: Codable { let error: String }
        if let failure = try? JSONDecoder().decode(FfiFailure.self, from: Data(raw.utf8)) {
            throw OpenCsvClientError.ffi(failure.error)
        }
        return raw
    }

    private static func encodeJson<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let json = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw OpenCsvClientError.decode("could not encode request")
        }
        return json
    }
}
