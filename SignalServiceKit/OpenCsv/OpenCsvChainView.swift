//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import OpenCsvFFI

/// The chain views a wallet can use, per opencsvnet/Signal-iOS#3.
///
/// They answer two different questions and must not be conflated:
///
/// - **Point verification** — does this anchor exist where the consignment
///   claims, with enough confirmations? Answered trustlessly by SPV:
///   PoW-validated headers, then one block, then a merkle branch. No server
///   is believed.
/// - **Exclusion** — has any of these nullifiers appeared *earlier*? The
///   on-chain payloads are deliberately not publicly derivable (that is
///   what stops mempool copy-griefing), so the record itself can never be
///   found by a filter. The default answer is the phone's own scan: anchor
///   transactions carry a constant marker output that BIP158 filters *do*
///   include, so a filter walk finds every anchor-bearing block, SPV
///   verifies each one, and exclusion becomes a local index lookup with no
///   server believed. Asking several independent indexers (any single
///   earlier sighting rejects) remains as a fallback for wallets that
///   cannot scan.
///
/// The anchor *record* is an OP_RETURN output, which basic filters exclude
/// entirely — only the marker is matchable. The `filterDiagnostic` field
/// that comes back from a point verification is exactly that — a
/// diagnostic — and plays no part in any verdict.
public enum OpenCsvChainView {

    // MARK: - Point verification (SPV)

    public struct SpvConfig: Codable {
        public let network: String
        public let peers: [String]
        public let cacheDir: String
        public let timeoutMs: UInt64

        public init(network: String, peers: [String], cacheDir: String, timeoutMs: UInt64 = 30_000) {
            self.network = network
            self.peers = peers
            self.cacheDir = cacheDir
            self.timeoutMs = timeoutMs
        }
    }

    public struct AnchorClaim: Codable {
        public let recordHex: String
        public let txidHex: String
        public let height: UInt64
        public let position: UInt32
        public let requiredConfirmations: UInt64

        public init(
            recordHex: String,
            txidHex: String,
            height: UInt64,
            position: UInt32,
            requiredConfirmations: UInt64,
        ) {
            self.recordHex = recordHex
            self.txidHex = txidHex
            self.height = height
            self.position = position
            self.requiredConfirmations = requiredConfirmations
        }
    }

    /// What SPV can establish about a claimed anchor.
    public struct SpvVerdict: Codable {
        public let status: String
        public let ctxHex: String?
        public let blockHashHex: String?
        public let confirmations: UInt64?
        public let reason: String?
        public let have: UInt64?
        public let required: UInt64?
        /// A BIP158 filter-match hint. **Never evidence** — basic filters
        /// exclude OP_RETURN, so this says nothing about whether the anchor
        /// is real. The verdict rests entirely on the merkle path.
        public let filterDiagnostic: Bool?

        public var isConfirmed: Bool { status == "confirmed" }
    }

    /// Verify a claimed anchor against the chain itself, trusting no server.
    public static func verifyAnchor(config: SpvConfig, claim: AnchorClaim) throws -> SpvVerdict {
        struct Request: Codable {
            let network: String
            let peers: [String]
            let cacheDir: String
            let timeoutMs: UInt64
            let anchor: AnchorClaim
        }
        let request = Request(
            network: config.network,
            peers: config.peers,
            cacheDir: config.cacheDir,
            timeoutMs: config.timeoutMs,
            anchor: claim,
        )
        return try call(encode(request)) { opencsv_cbf_verify_anchor($0) }
    }

    /// Current tip height as agreed by every configured peer.
    public static func syncTipHeight(config: SpvConfig) throws -> UInt64 {
        struct TipReply: Codable { let tipHeight: UInt64 }
        let reply: TipReply = try call(encode(config)) { opencsv_cbf_sync($0) }
        return reply.tipHeight
    }

    /// The anchor-snapshot JSON a verification runs against:
    /// `{"tip_height":N,"entries":[{"height","position","txid","ctx","record"},…]}`.
    /// Only the fields SPV needs are decoded.
    private struct SnapshotIndex: Codable {
        struct Entry: Codable {
            let height: UInt64
            let position: UInt32
            let txid: String
            let record: String
            let ctx: String?
        }

        let entries: [Entry]
    }

    /// The full snapshot entry at an anchor's location — what the explorer
    /// sheet shows (txid, record, ctx). Nil when the snapshot has no entry
    /// there.
    public static func snapshotEntryDetails(
        fromSnapshotJson snapshotJson: String,
        anchor: OpenCsvVerdict.Anchor,
    ) -> (txidHex: String, recordHex: String, ctxHex: String?)? {
        guard
            let index = try? decoder.decode(SnapshotIndex.self, from: Data(snapshotJson.utf8)),
            let entry = index.entries.first(where: {
                $0.height == anchor.height && $0.position == anchor.position
            })
        else {
            return nil
        }
        return (entry.txid, entry.record, entry.ctx)
    }

    /// Build the SPV claim for the snapshot entry a verified consignment's
    /// anchor points at.
    ///
    /// The crediting verify only proves the consignment matches this
    /// *entry*; SPV is what proves the entry matches the *chain*. Nil when
    /// the snapshot has no entry at that location — for a verdict produced
    /// against this same snapshot that is a programming error, since the
    /// verify cannot have succeeded without the entry.
    public static func anchorClaim(
        fromSnapshotJson snapshotJson: String,
        anchor: OpenCsvVerdict.Anchor,
        requiredConfirmations: UInt64,
    ) -> AnchorClaim? {
        guard
            let index = try? decoder.decode(SnapshotIndex.self, from: Data(snapshotJson.utf8)),
            let entry = index.entries.first(where: {
                $0.height == anchor.height && $0.position == anchor.position
            })
        else {
            return nil
        }
        return AnchorClaim(
            recordHex: entry.record,
            txidHex: entry.txid,
            height: entry.height,
            position: entry.position,
            requiredConfirmations: requiredConfirmations,
        )
    }

    // MARK: - Exclusion (N-of-M cross-check)

    /// One indexer to ask. Several independent ones are the point: a single
    /// backend can hide a double-spend, a quorum of independent ones cannot
    /// unless all are compromised.
    public enum Backend: Codable {
        case http(url: String)
        case snapshot(json: String)

        private enum CodingKeys: String, CodingKey { case type, url, snapshot }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .http(let url):
                try container.encode("http", forKey: .type)
                try container.encode(url, forKey: .url)
            case .snapshot(let json):
                try container.encode("snapshot", forKey: .type)
                try container.encode(
                    try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: AnyCodable] ?? [:],
                    forKey: .snapshot,
                )
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "http":
                self = .http(url: try container.decode(String.self, forKey: .url))
            case "snapshot":
                // AnyCodable is scalar-only, so nested snapshot payloads
                // degrade — matching the encoder's fidelity above.
                let payload = try container.decode([String: AnyCodable].self, forKey: .snapshot)
                let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? "{}"
                self = .snapshot(json: json)
            default:
                // A backend nobody recognises must be loud: decoding it as
                // an empty snapshot would silently weaken the cross-check.
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "unknown chain-view backend type \"\(type)\"",
                )
            }
        }
    }

    /// The outcome of asking every configured indexer.
    public struct CrossCheckVerdict: Codable {
        public let status: String?
        public let reason: String?
        public let error: String?
        /// Present when the backends disagree about the chain tip. This is
        /// a hard failure, never a silent majority pick: disagreement means
        /// at least one is wrong or lying, and which is unknowable here.
        public let kind: String?
        public let tips: [UInt64]?

        public var isVerified: Bool { status == "verified" }
        public var isTipDisagreement: Bool { kind == "tip_disagreement" }
    }

    /// Run the accept driver over several independent indexers.
    ///
    /// Read-only: it establishes whether the consignment should be
    /// believed, and never credits coins. Crediting stays with
    /// `verify_consignment` so the wallet's own bookkeeping has one path.
    public static func crossCheck(
        wallet: OpenCsvWallet,
        backends: [Backend],
        consignment: Data,
        requiredConfirmations: UInt64,
    ) throws -> CrossCheckVerdict {
        struct Request: Codable {
            let backends: [Backend]
            let consignmentBase64: String
            let requiredConfirmations: UInt64
        }
        let request = Request(
            backends: backends,
            consignmentBase64: consignment.base64EncodedString(),
            requiredConfirmations: requiredConfirmations,
        )
        let json = try encode(request)
        // A tip disagreement comes back as {"error":…,"kind":…}, which the
        // generic error path would otherwise throw away; decode it as a
        // verdict so callers can report *why* they refused.
        let raw = try json.withCString { pointer -> String in
            guard let out = opencsv_cross_check(wallet.rawHandle, pointer) else {
                throw OpenCsvClientError.ffi("cross-check returned null")
            }
            defer { opencsv_string_free(out) }
            return String(cString: out)
        }
        return try decoder.decode(CrossCheckVerdict.self, from: Data(raw.utf8))
    }

    /// Account-wallet form of `crossCheck`. Ownership remains inside Rust;
    /// using the legacy wallet here would reject valid account outputs as
    /// `NoOwnedOutput` before the unified account crediting path can run.
    public static func crossCheck(
        account: OpenCsvAccountWallet,
        backends: [Backend],
        consignment: Data,
        requiredConfirmations: UInt64,
    ) throws -> CrossCheckVerdict {
        struct Request: Codable {
            let backends: [Backend]
            let consignmentBase64: String
            let requiredConfirmations: UInt64
        }
        let request = Request(
            backends: backends,
            consignmentBase64: consignment.base64EncodedString(),
            requiredConfirmations: requiredConfirmations,
        )
        let raw = try encode(request).withCString { pointer -> String in
            guard let out = opencsv_account_cross_check(account.rawHandle, pointer) else {
                throw OpenCsvClientError.ffi("account cross-check returned null")
            }
            defer { opencsv_string_free(out) }
            return String(cString: out)
        }
        return try decoder.decode(CrossCheckVerdict.self, from: Data(raw.utf8))
    }

    // MARK: - Exclusion (self-scan)

    /// One filter walk of the chain for the protocol marker output,
    /// SPV-fetching the matching blocks into an occurrence index on disk
    /// under `<cacheDir>/scan`. The index resumes from its synced tip, so
    /// repeat syncs cost only the new blocks; a sync also registers the
    /// index as the one `scanVerify` consults.
    public struct ScanSyncConfig: Codable {
        public let network: String
        public let peers: [String]
        public let cacheDir: String
        public let timeoutMs: UInt64
        /// Where a fresh index starts scanning — the wallet's birth
        /// height. Use 1 to walk the whole chain's filters once; the FFI
        /// reserves 0 as its mempool sentinel and rejects it.
        public let fromHeight: UInt64
        public let requiredConfirmations: UInt64

        public init(
            network: String,
            peers: [String],
            cacheDir: String,
            timeoutMs: UInt64 = 30_000,
            fromHeight: UInt64,
            requiredConfirmations: UInt64,
        ) {
            self.network = network
            self.peers = peers
            self.cacheDir = cacheDir
            self.timeoutMs = timeoutMs
            self.fromHeight = fromHeight
            self.requiredConfirmations = requiredConfirmations
        }
    }

    /// What a sync cost, in bytes — the honest price of the trustless
    /// view, and worth logging: fake markers can inflate `blocksBytes`
    /// (bounded by the attacker's dust and fees), never correctness.
    public struct ScanSyncResult: Codable {
        public let tipHeight: UInt64
        public let filtersBytes: UInt64
        public let blocksBytes: UInt64
        public let anchors: UInt64
    }

    /// Sync the local occurrence index and register it for `scanVerify`.
    /// Does network I/O for up to `timeoutMs`; call off the payments actor.
    /// Re-dials peers on every call — prefer the persistent client below
    /// for repeat syncs.
    public static func scanSync(config: ScanSyncConfig) throws -> ScanSyncResult {
        try call(encode(config)) { opencsv_scan_sync($0) }
    }

    /// Open a persistent CBF client: one handshake, then `scanSyncWith`
    /// reuses the connections — the fixed ~1 s re-dial cost per sync
    /// disappears. Network I/O; call off the payments actor.
    public static func openCbfClient(config: ScanSyncConfig) throws -> UInt64 {
        struct OpenReply: Codable { let clientId: UInt64 }
        let reply: OpenReply = try call(encode(config)) { opencsv_cbf_open($0) }
        return reply.clientId
    }

    /// Sync on an already-open client's connections. Same result shape as
    /// `scanSync` (the extra `handshakes` diagnostic is ignored).
    public static func scanSyncWith(clientId: UInt64) throws -> ScanSyncResult {
        guard let out = opencsv_scan_sync_with(clientId) else {
            throw OpenCsvClientError.ffi("persistent scan sync returned null")
        }
        let raw: String
        do {
            defer { opencsv_string_free(out) }
            raw = String(cString: out)
        }
        if let failure = try? JSONDecoder().decode(FfiFailureJson.self, from: Data(raw.utf8)) {
            throw OpenCsvClientError.ffi(failure.error)
        }
        return try decoder.decode(ScanSyncResult.self, from: Data(raw.utf8))
    }

    /// Close a persistent client. Failing to close only leaks a socket
    /// until process exit; errors are not actionable and are swallowed.
    public static func closeCbfClient(clientId: UInt64) {
        if let out = opencsv_cbf_close(clientId) {
            opencsv_string_free(out)
        }
    }

    /// The outcome of running accept against the phone's own scan index.
    public struct ScanVerdict: Codable {
        public let status: String?
        public let reason: String?
        public let confirmations: UInt64?
        public let tipHeight: UInt64?

        public var isVerified: Bool { status == "verified" }
    }

    /// The anchor snapshot as the registered scan index sees it — the
    /// serverless source for the crediting path. `tip_height` is the
    /// index's synced tip, so confirmation counting in the crediting
    /// verify agrees with the scan's own view. Throws ("no scan
    /// registered") until a `scanSync` has succeeded this process.
    public static func exportScanSnapshot() throws -> String {
        guard let out = opencsv_scan_export_snapshot() else {
            throw OpenCsvClientError.ffi("scan export returned null")
        }
        defer { opencsv_string_free(out) }
        let raw = String(cString: out)
        if let failure = try? JSONDecoder().decode(FfiFailureJson.self, from: Data(raw.utf8)) {
            throw OpenCsvClientError.ffi(failure.error)
        }
        return raw
    }

    /// Decide a consignment against the local scan index. Fully local — no
    /// server is asked and none is believed, which is what earns the
    /// "verified by this phone" badge. Read-only: crediting stays with
    /// `verify_consignment` so the wallet's bookkeeping has one path.
    /// Throws ("no scan registered") until a `scanSync` has succeeded this
    /// process — callers treat that as infrastructure, never as rejection.
    public static func scanVerify(wallet: OpenCsvWallet, consignment: Data) throws -> ScanVerdict {
        let raw = try consignment.hexadecimalString.withCString { pointer -> String in
            guard let out = opencsv_scan_verify(wallet.rawHandle, pointer) else {
                throw OpenCsvClientError.ffi("scan verify returned null")
            }
            defer { opencsv_string_free(out) }
            return String(cString: out)
        }
        if let failure = try? JSONDecoder().decode(FfiFailureJson.self, from: Data(raw.utf8)) {
            throw OpenCsvClientError.ffi(failure.error)
        }
        return try decoder.decode(ScanVerdict.self, from: Data(raw.utf8))
    }

    /// Account-wallet form of `scanVerify`; this is the product path. The
    /// local index remains read-only while Rust checks ownership against the
    /// same account that will receive and persist the credit.
    public static func scanVerify(
        account: OpenCsvAccountWallet,
        consignment: Data,
    ) throws -> ScanVerdict {
        let raw = try consignment.hexadecimalString.withCString { pointer -> String in
            guard let out = opencsv_account_scan_verify(account.rawHandle, pointer) else {
                throw OpenCsvClientError.ffi("account scan verify returned null")
            }
            defer { opencsv_string_free(out) }
            return String(cString: out)
        }
        if let failure = try? JSONDecoder().decode(FfiFailureJson.self, from: Data(raw.utf8)) {
            throw OpenCsvClientError.ffi(failure.error)
        }
        return try decoder.decode(ScanVerdict.self, from: Data(raw.utf8))
    }

    // MARK: - Plumbing

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let json = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw OpenCsvClientError.decode("could not encode a chain-view request")
        }
        return json
    }

    private static func call<T: Decodable>(
        _ json: String,
        _ body: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?,
    ) throws -> T {
        let raw = try json.withCString { pointer -> String in
            guard let out = body(pointer) else {
                throw OpenCsvClientError.ffi("chain view returned null")
            }
            defer { opencsv_string_free(out) }
            return String(cString: out)
        }
        if let failure = try? JSONDecoder().decode(FfiFailureJson.self, from: Data(raw.utf8)) {
            throw OpenCsvClientError.ffi(failure.error)
        }
        do {
            return try decoder.decode(T.self, from: Data(raw.utf8))
        } catch {
            throw OpenCsvClientError.decode("\(error): \(raw.prefix(200))")
        }
    }
}

/// `{"error": "..."}`, the shape every FFI call uses to report failure.
private struct FfiFailureJson: Codable {
    let error: String
}

/// Minimal passthrough so an inline snapshot can be embedded verbatim.
public struct AnyCodable: Codable {
    private let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { value = string } else if
            let int = try? container.decode(Int.self) { value = int } else if
            let bool = try? container.decode(Bool.self) { value = bool } else
        {
            value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String: try container.encode(string)
        case let int as Int: try container.encode(int)
        case let bool as Bool: try container.encode(bool)
        default: try container.encodeNil()
        }
    }
}
