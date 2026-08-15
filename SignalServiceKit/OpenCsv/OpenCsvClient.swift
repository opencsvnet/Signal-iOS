//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import OpenCsvFFI

/// Errors surfaced by the OpenCSV FFI boundary.
public enum OpenCsvClientError: Error, Equatable, CustomStringConvertible {
    /// The Rust side reported a failure (`{"error": ...}`).
    case ffi(String)
    /// A structured account-wallet failure. `reason` is the stable API;
    /// `message` is display/debug detail and must never drive state.
    case ffiFailure(reason: String, message: String, retryable: Bool?)
    /// The FFI returned JSON we could not decode.
    case decode(String)

    public var ffiReason: String? {
        guard case .ffiFailure(let reason, _, _) = self else { return nil }
        return reason
    }

    public var ffiMessage: String? {
        switch self {
        case .ffi(let message), .decode(let message): message
        case .ffiFailure(_, let message, _): message
        }
    }

    public var description: String {
        switch self {
        case .ffi(let message), .decode(let message): message
        case .ffiFailure(let reason, let message, _): "\(reason): \(message)"
        }
    }
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

/// Public issuer identities reviewed into this build. These entries grant
/// wallet presentation trust only; they contain no issuer secret and cannot
/// authorize minting. Mainnet remains empty until an issuer relationship and
/// manifest have received a separate production review.
public enum OpenCsvReviewedUsdIssuers {
    /// Application deployment identity. Bitcoin Signet is unchanged; this
    /// value prevents v1 wallet or backup state from being interpreted as v2.
    public static let testUsdDeploymentId = "opencsv-test-usd-v2"
    public static let testUsdCheckpointVersion: UInt32 = 4

    /// Exact asset identity of Signal's no-value v2 signet product, copied
    /// from the headless issuer's backed-up canonical manifest. It is never
    /// derived from the `USD` display code.
    public static let signetTestUsdAssetId = "8a88b56e42450f5761b521063df3fa16806add5c434584441d3b626556115d62"

    /// Earliest height relevant to the reviewed instrument set in this
    /// build. The signet preview registry was activated after this public
    /// checkpoint, so a fresh wallet does not need to walk hundreds of
    /// thousands of irrelevant compact filters. Adding an older reviewed
    /// instrument must deliberately lower this value in the same review.
    public static func earliestRelevantHeight(for network: String) -> UInt64? {
        network == "signet" ? 316_000 : nil
    }

    public static func policies(for network: String) -> [OpenCsvUsdIssuerPolicy] {
        guard network == "signet" else { return [] }
        return [
            OpenCsvUsdIssuerPolicy(
                manifest: OpenCsvInstrumentManifest(
                    terms: OpenCsvInstrumentTerms(
                        network: "signet",
                        displayName: "OpenCSV Test USD v2",
                        unitCode: "USD",
                        decimals: 6,
                        issuerName: "OpenCSV Test Issuer v2",
                        termsUri: "https://opencsv.net/usd-preview/terms-v2",
                        redemptionSummary: "Test-only units with no monetary or redemption value.",
                        testOnly: true,
                    ),
                    genesis: .init(
                        issuerPk: [85, 229, 121, 32, 170, 211, 54, 96, 232, 129, 85, 8, 229, 135, 245, 106, 205, 109, 65, 111, 140, 192, 44, 73, 157, 193, 138, 68, 41, 242, 37, 109],
                        currencyCode: Array("USD".utf8),
                        termsHash: [196, 2, 2, 117, 244, 225, 86, 119, 89, 142, 110, 1, 241, 176, 125, 41, 167, 216, 254, 8, 166, 4, 250, 16, 16, 111, 104, 11, 179, 115, 18, 115],
                        nonce: 1,
                    ),
                ),
                priority: 0,
            ),
        ]
    }
}

/// Product names shown by Signal. Protocol data continues to use `USD`;
/// presentation upgrades it to `Test USD` only for the exact reviewed,
/// test-only signet instrument.
public enum OpenCsvProductPresentation {
    public static func currencyName(currency: String?, assetId: String?) -> String {
        guard
            currency == "USD",
            assetId == OpenCsvReviewedUsdIssuers.signetTestUsdAssetId,
            OpenCsvReviewedUsdIssuers.policies(for: "signet").contains(where: {
                $0.manifest.terms.network == "signet"
                    && $0.manifest.terms.unitCode == "USD"
                    && $0.manifest.terms.testOnly
            })
        else {
            return currency ?? ""
        }
        return "Test USD"
    }

    public static func currencyName(
        network: String,
        instruments: [OpenCsvInstrumentRecord],
    ) -> String {
        let reviewedTestManifests = OpenCsvReviewedUsdIssuers.policies(for: network).compactMap {
            $0.manifest.terms.testOnly ? $0.manifest : nil
        }
        guard
            network == "signet",
            instruments.contains(where: {
                $0.assetId == OpenCsvReviewedUsdIssuers.signetTestUsdAssetId
                    && $0.profile == "trusted_test_usd_v2"
                    && $0.trustState == "trusted_configuration"
                    && $0.manifest.map { reviewedTestManifests.contains($0) } == true
            })
        else {
            return "USD"
        }
        return "Test USD"
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
    public let finality: String?
    public let anchorTxid: String?
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
    /// `unconfirmed` means the proof and exact mempool transaction verified
    /// and Rust may select the coins, but every child signing must re-observe
    /// that exact parent. `settled` met the configured confirmation depth.
    public let finality: String?
    public let spendable: Bool?
    public let risk: String?
    public let anchorTxid: String?
    /// Stable identity over Rust's canonical consignment encoding. Signal
    /// keys verdict and rendered-cell state by this value, never by an
    /// attachment id or delivery-attempt nonce.
    public let consignmentId: String?
    /// Stable identity over the proof-protected payment fields, excluding
    /// only the replaceable Bitcoin anchor txid.
    public let paymentId: String?
    /// Canonical consignments for the same payment that this verified
    /// replacement supersedes.
    public let supersededConsignmentIds: [String]?
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
        paymentId: String? = nil,
        supersededConsignmentIds: [String]? = nil,
        finality: String? = nil,
        spendable: Bool? = nil,
        risk: String? = nil,
        anchorTxid: String? = nil,
    ) {
        self.status = status
        self.reason = reason
        self.credits = credits
        self.coins = coins
        self.anchor = anchor
        self.consignmentId = consignmentId
        self.paymentId = paymentId
        self.supersededConsignmentIds = supersededConsignmentIds
        self.finality = finality
        self.spendable = spendable
        self.risk = risk
        self.anchorTxid = anchorTxid
    }
}

// MARK: - Signal-native account wallet

public enum OpenCsvAccountRole: String, Codable, Equatable {
    case primary
    case linked
}

public enum OpenCsvObservationMode: String, Codable, Equatable, Sendable {
    case off
    case observe
    case require
}

public enum OpenCsvObservationKind: String, Codable, Equatable, Sendable {
    case rawTransactionApi = "raw_transaction_api"
    case directP2pRelay = "direct_p2p_relay"
    case experimentalP2pPossession = "experimental_p2p_possession"
    case confirmedSpv = "confirmed_spv"
}

public struct OpenCsvObservationCheck: Codable, Equatable, Sendable {
    public let id: String
    public let kind: OpenCsvObservationKind
    public let endpoint: String?
    public let mode: OpenCsvObservationMode
    public let pinProfile: String?
    public let chainFingerprintsSha256: [String]
    public let maxAgeSeconds: UInt64

    public static func defaults(for network: String) -> [Self] {
        var checks: [Self] = []
        if network == "signet" || network == "mainnet" {
            let suffix = network == "mainnet" ? "mainnet" : "signet"
            let path = network == "mainnet" ? "" : "/signet"
            checks += [
                Self(
                    id: "mempool_space_\(suffix)",
                    kind: .rawTransactionApi,
                    endpoint: "https://mempool.space\(path)/api",
                    mode: .require,
                    pinProfile: "sectigo_r46",
                    chainFingerprintsSha256: [
                        "6542d176bed50f193c0ce297ae44ecd8a0a86bec2ede682769344059b4e78530",
                        "92f351bf3d54164dfa8dd8f9e1139d3150349786485d2b9eecd00e2971c1e6c5",
                    ],
                ),
                Self(
                    id: "blockstream_\(suffix)",
                    kind: .rawTransactionApi,
                    endpoint: "https://blockstream.info\(path)/api",
                    mode: .require,
                    pinProfile: "lets_encrypt_yr",
                    chainFingerprintsSha256: [
                        "13949634d99cd6fd6aa80bc034fefacceb1969feef986586713ecdbb05758d3f",
                        "238b85a0099c65b970477d5724f1a1d475ce5058cffe4efa8733899bdb863c47",
                        "e57b7e6f150c419102e8d5c055729ff967b9d1a829bf00cec89ca604ebf4a86f",
                        "072639d0b140d5bffae16ad9c3f6cc6086040621f51ee61a6d46a8915c07cf76",
                    ],
                ),
            ]
        }
        checks += [
            Self(id: "direct_p2p_relay", kind: .directP2pRelay, mode: .observe),
            Self(id: "experimental_p2p_mempool_possession", kind: .experimentalP2pPossession, mode: .off),
            Self(id: "multi_peer_spv_confirmation", kind: .confirmedSpv, mode: .observe),
        ]
        return checks
    }

    public init(
        id: String,
        kind: OpenCsvObservationKind,
        endpoint: String? = nil,
        mode: OpenCsvObservationMode,
        pinProfile: String? = nil,
        chainFingerprintsSha256: [String] = [],
        maxAgeSeconds: UInt64 = 120,
    ) {
        self.id = id
        self.kind = kind
        self.endpoint = endpoint
        self.mode = mode
        self.pinProfile = pinProfile
        self.chainFingerprintsSha256 = chainFingerprintsSha256
        self.maxAgeSeconds = maxAgeSeconds
    }
}

public struct OpenCsvObservationEvidence: Codable, Equatable, Sendable {
    public let checkId: String
    public let endpoint: String?
    public let result: String
    public let startedAtMs: Int64
    public let completedAtMs: Int64
    public let cachedAtMs: Int64
    public let certificateProfile: String?
    public let certificateChainFingerprintsSha256: [String]
    public let rawTransactionHex: String?
    public let detail: String?
}

/// Public policy supplied when opening the Rust-owned account wallet. Secret
/// keys, Bitcoin inputs, change addresses and transaction bytes are
/// intentionally absent.
public struct OpenCsvAccountConfig: Codable, Equatable {
    public let version: UInt32
    public let deploymentId: String
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
    public let observationChecks: [OpenCsvObservationCheck]
    /// Required exact pinned raw-transaction observations. This is derived as
    /// every raw-transaction check marked `require`, so a required provider
    /// can never be silently treated as an optional quorum member.
    public let requiredRawObserverQuorum: UInt32
    public let watchExternalDescriptor: String?
    public let watchInternalDescriptor: String?
    public let watchOwner: String?
    /// Reviewed, public issuer manifests admitted under the single USD
    /// product. App review/configuration is the current trust root; this
    /// never contains issuer secrets or enables issuance.
    public let usdIssuers: [OpenCsvUsdIssuerPolicy]

    public init(
        version: UInt32 = 2,
        deploymentId: String? = nil,
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
        observationChecks: [OpenCsvObservationCheck]? = nil,
        watchExternalDescriptor: String? = nil,
        watchInternalDescriptor: String? = nil,
        watchOwner: String? = nil,
        usdIssuers: [OpenCsvUsdIssuerPolicy] = [],
    ) {
        self.version = version
        self.deploymentId = deploymentId ?? (
            network == "mainnet" ? "opencsv-mainnet" : OpenCsvReviewedUsdIssuers.testUsdDeploymentId
        )
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
        let resolvedObservationChecks = observationChecks ?? OpenCsvObservationCheck.defaults(for: network)
        self.observationChecks = resolvedObservationChecks
        self.requiredRawObserverQuorum = UInt32(clamping: resolvedObservationChecks.filter {
            $0.kind == .rawTransactionApi && $0.mode == .require
        }.count)
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

    public struct BatchReserves: Codable, Equatable {
        public struct Inventory: Codable, Equatable {
            public let participantCount: UInt8
            public let state: String
            public let count: UInt
            public let totalSats: UInt64
        }

        public struct Maintenance: Codable, Equatable {
            public let maintenanceId: String
            public let state: String
            public let participantCount: UInt8
            public let stockCount: UInt8
            public let feeCellCount: UInt16
            public let txid: String
            public let feeRateSatPerVb: UInt64?
            public let updatedAt: Int64
        }

        public let inventory: [Inventory]
        public let maintenanceOperations: [Maintenance]
    }

    public struct SyncProvenance: Codable, Equatable {
        public let accelerator: String
        public let authoritative: String
        public let verificationPeerCount: UInt
        public let lastSyncAt: String?
        public let lastSyncTip: String?

        /// Rust deliberately returns these as strings across the stable JSON
        /// boundary. Keep parsing in one place so presentation code never
        /// guesses whether the timestamp is ISO-8601 or Unix seconds.
        public var lastSyncDate: Date? {
            lastSyncAt.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        }

        public var lastSyncHeight: UInt64? {
            lastSyncTip.flatMap(UInt64.init)
        }
    }

    public let version: UInt32
    public let deploymentId: String
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
    public let writeBlockReason: String?
    public let productionUsdConfigured: Bool?
    public let productionObservationPolicyReady: Bool?
    /// Always false for Signal's owner-only wallet boundary.
    public let issuanceEnabled: Bool
    public let deviceBinding: DeviceBinding
    public let syncProvenance: SyncProvenance
    public let observationPolicy: [OpenCsvObservationCheck]?
    public let requiredRawObserverQuorum: UInt32?
    public let observationReceipts: [OpenCsvObservationReceipt]?
    public let batchReserves: BatchReserves?
    public let rootFingerprint: String
}

public struct OpenCsvObservationReceipt: Codable, Equatable {
    public let checkId: String
    public let kind: OpenCsvObservationKind
    public let mode: OpenCsvObservationMode
    public let endpoint: String?
    public let result: String
    public let startedAtMs: Int64
    public let completedAtMs: Int64
    public let latencyMs: Int64
    public let cachedAtMs: Int64
    public let cacheAgeMs: Int64
    public let certificateProfile: String?
    public let certificateChainFingerprintsSha256: [String]
    public let rawByteMatch: Bool
    public let detail: String?
    public let failures: [String]
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
    public struct BatchMembership: Codable, Equatable {
        public let batchLocalId: String
        public let state: String
        public let deadlineMs: Int64
        public let ordinal: UInt8
        public let addedAtMs: Int64
        public let memberCount: UInt
        public let addRecipientGuaranteed: Bool
    }

    public struct Receipt: Codable, Equatable {
        public let txid: String?
        public let feeSats: UInt64?
        public let feeRateSatPerVb: UInt64?
        public let deliveryNonce: String?
        public let consignmentId: String?
        public let consignmentBase64: String?
        public let deliveryReady: Bool?
        public let consignmentDelivered: Bool?
        public let replaces: String?
        public let supersededConsignmentIds: [String]?
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
    public let batch: BatchMembership?
}

public struct OpenCsvSendBatch: Codable, Equatable {
    public let batchLocalId: String
    public let state: String
    public let deadlineMs: Int64
    public let participantCount: UInt8?
    public let memberCount: UInt
    public let operations: [OpenCsvAccountOperation]
    public let proposalWireBase64: String?
    public let manifestWireBase64: String?
    public let signedTxHex: String?
    public let txid: String?
    public let checkpointHash: String?
    public let backupAcked: Bool
}

public enum OpenCsvSendBatchProofResult: Equatable {
    case solo(operationId: String)
    case batch(OpenCsvSendBatch)
}

public struct OpenCsvBatchReserveOperation: Codable, Equatable {
    public let maintenanceId: String
    public let state: String
    public let participantCount: UInt8
    public let stockCount: UInt8
    public let feeCellCount: UInt16
    public let signedTxHex: String
    public let txid: String
    public let feeRateSatPerVb: UInt64?
}

enum OpenCsvBatchReservePolicy {
    /// The live Signet reserve stalled below a broad 3 sat/vB mempool band.
    /// Four clears that observed floor while keeping the fixed count-2 split
    /// below the wallet's 2,000-sat maintenance ceiling.
    static let targetSatPerVb: UInt64 = 4

    static func shouldFeeBump(state: String, feeRateSatPerVb: UInt64?) -> Bool {
        ["broadcast_unobserved", "mempool"].contains(state)
            && (feeRateSatPerVb ?? 0) < targetSatPerVb
    }

    static func shouldFeeBump(_ operation: OpenCsvBatchReserveOperation) -> Bool {
        shouldFeeBump(state: operation.state, feeRateSatPerVb: operation.feeRateSatPerVb)
    }
}

public enum OpenCsvFeeBumpPolicy {
    /// An OpenCSV operation remains at `mempool` until the phone-owned scan
    /// reaches the protocol settlement depth. Bitcoin RBF ends earlier: once
    /// the wallet's change output is confirmed, ordinary peers will not
    /// accept a replacement. Keep the cached UI conservative by offering the
    /// action only while the candidate's own change is still present and the
    /// wallet reports pending value. Rust remains the final authority when
    /// wallets contain a mixture of confirmed and pending outputs.
    public static func shouldOffer(
        operation: OpenCsvAccountOperationSummary,
        feeReserve: OpenCsvAccountStatus.FeeReserve,
    ) -> Bool {
        guard
            ["broadcast_unobserved", "broadcast", "mempool"].contains(operation.state),
            let txid = operation.txid,
            feeReserve.utxos.contains(where: { $0.txid == txid })
        else {
            return false
        }
        return feeReserve.trustedPendingSats > 0 || feeReserve.untrustedPendingSats > 0
    }
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

#if DEBUG && OPENCSV_TEST_WALLET_RECOVERY
public struct OpenCsvTestDeviceRebindResponse: Equatable {
    public let status: String
    public let idempotent: Bool
    public let backupRequired: Bool
    public let writeEnabled: Bool
    public let deviceBindingCommitment: String
    public let checkpoint: OpenCsvAccountCheckpoint
    /// Exact full checkpoint envelope returned by Rust. The public summary
    /// above intentionally omits private coin and operation fields, so it
    /// must never be re-encoded for Secure Backup.
    public let checkpointJson: String
}
#endif

public struct OpenCsvConsignmentInspection: Codable, Equatable {
    public let consignmentId: String
    public let paymentId: String
    public let anchorTxid: String
    public let anchorHeight: UInt64
    public let anchorPosition: UInt32
    /// Exact public asset identities carried by the recipient openings.
    public let assetIds: [String]
    /// Rust derives this from Signal's immutable reviewed-issuer registry.
    public let allAssetsReviewed: Bool
    public let unreviewedAssetIds: [String]
    /// Stable policy result; currently `asset_not_reviewed` when present.
    public let rejectionReason: String?
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

    public func prepareBatchReserves(
        participantCount: UInt8,
        targetSatPerVb: UInt64,
        maxFeeSats: UInt64? = nil,
    ) throws -> OpenCsvBatchReserveOperation {
        struct FeePolicy: Codable {
            let targetSatPerVb: UInt64
            let maxFeeSats: UInt64?
        }
        let policy = try Self.encodeJson(FeePolicy(
            targetSatPerVb: targetSatPerVb,
            maxFeeSats: maxFeeSats,
        ))
        return try policy.withCString {
            try Self.take(opencsv_account_prepare_batch_reserves(handle, participantCount, $0))
        }
    }

    public func observeBatchReserves(
        maintenanceId: String,
        rawTransaction: Data,
        observations: [OpenCsvObservationEvidence],
    ) throws -> OpenCsvBatchReserveOperation {
        guard !rawTransaction.isEmpty else {
            throw OpenCsvClientError.ffi("reserve observer transaction is empty")
        }
        struct Envelope: Encodable { let observations: [OpenCsvObservationEvidence] }
        let evidenceJson = try Self.encodeJson(Envelope(observations: observations))
        return try maintenanceId.withCString { maintenance in
            try rawTransaction.withUnsafeBytes { bytes in
                try evidenceJson.withCString { evidence in
                    try Self.take(opencsv_account_observe_batch_reserves(
                        handle,
                        maintenance,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        rawTransaction.count,
                        evidence,
                    ))
                }
            }
        }
    }

    public func resumeBatchReserves(_ maintenanceId: String) throws -> OpenCsvBatchReserveOperation {
        try maintenanceId.withCString {
            try Self.take(opencsv_account_resume_batch_reserves(handle, $0))
        }
    }

    public func feeBumpBatchReserves(
        _ maintenanceId: String,
        targetSatPerVb: UInt64,
    ) throws -> OpenCsvBatchReserveOperation {
        try maintenanceId.withCString {
            try Self.take(opencsv_account_fee_bump_batch_reserves(handle, $0, targetSatPerVb))
        }
    }

    public func refreshBatchReserves(_ maintenanceId: String) throws -> OpenCsvBatchReserveOperation {
        try maintenanceId.withCString {
            try Self.take(opencsv_account_refresh_batch_reserves(handle, $0))
        }
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

#if DEBUG && OPENCSV_TEST_WALLET_RECOVERY
    /// Test-only signet/regtest device rebind. The Rust symbol and this method
    /// are both absent from normal DEBUG and every release build.
    public func rebindTestDevice(deviceBinding: Data) throws -> OpenCsvTestDeviceRebindResponse {
        guard deviceBinding.count == 32 else {
            throw OpenCsvClientError.ffi("device binding must be exactly 32 bytes")
        }
        struct WireResponse: Decodable {
            let status: String
            let idempotent: Bool
            let backupRequired: Bool
            let writeEnabled: Bool
            let deviceBindingCommitment: String
            let checkpoint: OpenCsvAccountCheckpoint
        }
        let raw = try deviceBinding.withUnsafeBytes { bytes in
            try Self.takeRaw(opencsv_account_rebind_test_device(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                deviceBinding.count,
            ))
        }
        let wire: WireResponse = try Self.decode(raw)
        guard
            let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            let checkpointObject = object["checkpoint"],
            JSONSerialization.isValidJSONObject(checkpointObject)
        else {
            throw OpenCsvClientError.decode("test rebind response omitted its full checkpoint")
        }
        let checkpointData = try JSONSerialization.data(withJSONObject: checkpointObject, options: [.sortedKeys])
        guard let checkpointJson = String(data: checkpointData, encoding: .utf8) else {
            throw OpenCsvClientError.decode("test rebind checkpoint was not UTF-8 JSON")
        }
        return OpenCsvTestDeviceRebindResponse(
            status: wire.status,
            idempotent: wire.idempotent,
            backupRequired: wire.backupRequired,
            writeEnabled: wire.writeEnabled,
            deviceBindingCommitment: wire.deviceBindingCommitment,
            checkpoint: wire.checkpoint,
            checkpointJson: checkpointJson,
        )
    }
#endif

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

    public func inspect(blob: Data) throws -> OpenCsvConsignmentInspection {
        guard !blob.isEmpty else {
            throw OpenCsvClientError.ffi("consignment is empty")
        }
        return try blob.withUnsafeBytes { bytes in
            try Self.take(opencsv_account_inspect_consignment(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                blob.count,
            ))
        }
    }

    /// Verify and credit an exact mempool-observed anchor without pretending
    /// it is settled. Rust validates the transaction layout, tags every coin
    /// with its parent txid, and rechecks that dependency before child sends.
    public func verifyUnconfirmed(blob: Data, confirmedSnapshotJson: String) throws -> OpenCsvVerdict {
        guard !blob.isEmpty else {
            throw OpenCsvClientError.ffi("consignment is empty")
        }
        return try blob.withUnsafeBytes { bytes in
            try confirmedSnapshotJson.withCString { snapshot in
                try Self.take(opencsv_account_verify_consignment_unconfirmed(
                    handle,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    blob.count,
                    snapshot,
                ))
            }
        }
    }

    public func verifyUnconfirmed(
        blob: Data,
        confirmedSnapshotJson: String,
        rawTransaction: Data,
        observations: [OpenCsvObservationEvidence],
    ) throws -> OpenCsvVerdict {
        guard !blob.isEmpty, !rawTransaction.isEmpty else {
            throw OpenCsvClientError.ffi("consignment and raw transaction must be non-empty")
        }
        struct Envelope: Encodable { let observations: [OpenCsvObservationEvidence] }
        let evidenceJson = try Self.encodeJson(Envelope(observations: observations))
        return try blob.withUnsafeBytes { blobBytes in
            try rawTransaction.withUnsafeBytes { transactionBytes in
                try confirmedSnapshotJson.withCString { snapshot in
                    try evidenceJson.withCString { evidence in
                        try Self.take(opencsv_account_verify_consignment_unconfirmed_observed(
                            handle,
                            blobBytes.bindMemory(to: UInt8.self).baseAddress,
                            blob.count,
                            snapshot,
                            transactionBytes.bindMemory(to: UInt8.self).baseAddress,
                            rawTransaction.count,
                            evidence,
                        ))
                    }
                }
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

    /// Persist the exact transfer intent and return before proof generation.
    /// The response is the same public operation shape used by status calls;
    /// it contains no selected coins, Bitcoin input, change address, or key.
    public func planTransfer(assetId: String, toOwner: String, amount: UInt64) throws -> OpenCsvAccountOperation {
        struct Request: Codable {
            let assetId: String
            let toOwner: String
            let amount: UInt64
        }
        return try callJson(
            Request(assetId: assetId, toOwner: toOwner, amount: amount),
            opencsv_transfer_plan,
        )
    }

    /// Start or join the wallet-owned two-second collection window.
    public func planBatchedTransfer(
        assetId: String,
        toOwner: String,
        amount: UInt64,
    ) throws -> OpenCsvAccountOperation {
        struct Request: Codable {
            let assetId: String
            let toOwner: String
            let amount: UInt64
        }
        return try callJson(
            Request(assetId: assetId, toOwner: toOwner, amount: amount),
            opencsv_transfer_batch_plan,
        )
    }

    /// Add Recipient only succeeds while Rust can durably guarantee the same
    /// frozen Bitcoin transaction. Expiry creates no surprise solo send.
    public func addBatchedRecipient(
        batchLocalId: String,
        assetId: String,
        toOwner: String,
        amount: UInt64,
    ) throws -> OpenCsvAccountOperation {
        struct Request: Codable {
            let assetId: String
            let toOwner: String
            let amount: UInt64
        }
        let request = try Self.encodeJson(Request(
            assetId: assetId,
            toOwner: toOwner,
            amount: amount,
        ))
        return try batchLocalId.withCString { batch in
            try request.withCString { request in
                try Self.take(opencsv_transfer_batch_add_recipient(handle, batch, request))
            }
        }
    }

    public func freezeSendBatch(_ batchLocalId: String) throws -> OpenCsvSendBatch {
        try batchLocalId.withCString {
            try Self.take(opencsv_send_batch_freeze(handle, $0))
        }
    }

    public func sendBatchStatus(_ batchLocalId: String) throws -> OpenCsvSendBatch {
        try batchLocalId.withCString {
            try Self.take(opencsv_send_batch_status(handle, $0))
        }
    }

    /// Abandon the complete ordered batch before Rust releases any
    /// signature. Signal never cancels one member out from under the frozen
    /// manifest because that would make the remaining UI claim misleading.
    public func cancelSendBatch(_ batchLocalId: String) throws -> OpenCsvSendBatch {
        try batchLocalId.withCString {
            try Self.take(opencsv_send_batch_cancel(handle, $0))
        }
    }

    public func proveSendBatch(_ batchLocalId: String) throws -> OpenCsvSendBatchProofResult {
        let raw = try batchLocalId.withCString {
            try Self.takeRaw(opencsv_send_batch_prove(handle, $0))
        }
        struct Solo: Decodable {
            let path: String?
            let operationId: String?
        }
        if let solo: Solo = try? Self.decode(raw), solo.path == "solo", let operationId = solo.operationId {
            return .solo(operationId: operationId)
        }
        return .batch(try Self.decode(raw))
    }

    public func acknowledgeSendBatchBackup(
        batchLocalId: String,
        checkpointHash: String,
    ) throws -> OpenCsvSendBatch {
        try batchLocalId.withCString { batch in
            try checkpointHash.withCString { checkpoint in
                try Self.take(opencsv_send_batch_ack_backup(handle, batch, checkpoint))
            }
        }
    }

    public func signAndBroadcastSendBatch(_ batchLocalId: String) throws -> OpenCsvSendBatch {
        try batchLocalId.withCString {
            try Self.take(opencsv_send_batch_sign_and_broadcast(handle, $0))
        }
    }

    public func observeUnconfirmedSendBatch(
        _ batchLocalId: String,
        rawTransaction: Data,
        observations: [OpenCsvObservationEvidence],
    ) throws -> OpenCsvSendBatch {
        guard !rawTransaction.isEmpty else {
            throw OpenCsvClientError.ffi("batch observer transaction is empty")
        }
        struct Envelope: Encodable { let observations: [OpenCsvObservationEvidence] }
        let evidenceJson = try Self.encodeJson(Envelope(observations: observations))
        return try batchLocalId.withCString { batch in
            try rawTransaction.withUnsafeBytes { bytes in
                try evidenceJson.withCString { evidence in
                    try Self.take(opencsv_send_batch_observe_unconfirmed(
                        handle,
                        batch,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        rawTransaction.count,
                        evidence,
                    ))
                }
            }
        }
    }

    public func resumeSendBatch(_ batchLocalId: String) throws -> OpenCsvSendBatch {
        try batchLocalId.withCString {
            try Self.take(opencsv_send_batch_resume(handle, $0))
        }
    }

    public func feeBumpSendBatch(
        _ batchLocalId: String,
        targetSatPerVb: UInt64,
    ) throws -> OpenCsvSendBatch {
        try batchLocalId.withCString {
            try Self.take(opencsv_send_batch_fee_bump(handle, $0, targetSatPerVb))
        }
    }

    public func refreshSendBatchSpv(_ batchLocalId: String) throws -> OpenCsvSendBatch {
        try batchLocalId.withCString {
            try Self.take(opencsv_send_batch_refresh_spv(handle, $0))
        }
    }

    /// Advance a durable planned/fee-reserved operation to proof-ready. A
    /// repeated call after proof-ready returns the exact stored receipt.
    public func proveOperation(_ operationId: String) throws -> OpenCsvPreparedOperation {
        try operationId.withCString { try Self.take(opencsv_operation_prove(handle, $0)) }
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

    public func refreshOperationSpv(_ operationId: String) throws -> OpenCsvAccountOperation {
        try operationId.withCString { try Self.take(opencsv_operation_refresh_spv(handle, $0)) }
    }

    public func observeUnconfirmedOperation(
        _ operationId: String,
        rawTransaction: Data,
        observations: [OpenCsvObservationEvidence],
    ) throws -> OpenCsvAccountOperation {
        guard !rawTransaction.isEmpty else {
            throw OpenCsvClientError.ffi("observer transaction is empty")
        }
        struct Envelope: Encodable { let observations: [OpenCsvObservationEvidence] }
        let evidenceJson = try Self.encodeJson(Envelope(observations: observations))
        return try operationId.withCString { operation in
            try rawTransaction.withUnsafeBytes { bytes in
                try evidenceJson.withCString { evidence in
                    try Self.take(opencsv_operation_observe_unconfirmed(
                        handle,
                        operation,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        rawTransaction.count,
                        evidence,
                    ))
                }
            }
        }
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
            let reason: String?
            let retryable: Bool?
        }
        if let failure = try? JSONDecoder().decode(FfiFailure.self, from: Data(raw.utf8)) {
            if let reason = failure.reason {
                throw OpenCsvClientError.ffiFailure(
                    reason: reason,
                    message: failure.error,
                    retryable: failure.retryable,
                )
            }
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
        struct FfiFailure: Codable {
            let error: String
            let reason: String?
            let retryable: Bool?
        }
        if let failure = try? JSONDecoder().decode(FfiFailure.self, from: Data(raw.utf8)) {
            if let reason = failure.reason {
                throw OpenCsvClientError.ffiFailure(
                    reason: reason,
                    message: failure.error,
                    retryable: failure.retryable,
                )
            }
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
