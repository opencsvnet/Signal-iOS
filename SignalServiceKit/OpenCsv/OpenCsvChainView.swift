//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import OpenCsvFFI

/// The three chain views a wallet can use, per opencsvnet/Signal-iOS#3.
///
/// They answer two different questions and must not be conflated:
///
/// - **Point verification** — does this anchor exist where the consignment
///   claims, with enough confirmations? Answered trustlessly by SPV:
///   PoW-validated headers, then one block, then a merkle branch. No server
///   is believed.
/// - **Exclusion** — has any of these nullifiers appeared *earlier*?
///   Unanswerable by SPV, because the on-chain payloads are deliberately
///   not publicly derivable (that is what stops mempool copy-griefing), so
///   it needs indexers. Trust is reduced by asking several independent ones
///   and letting any single honest answer reject: hiding a double-spend
///   requires compromising all of them.
///
/// BIP158 compact filters cannot help with either: basic filters exclude
/// OP_RETURN outputs entirely, so anchor records are unmatchable. The
/// `filterDiagnostic` field that comes back from a verification is exactly
/// that — a diagnostic — and plays no part in any verdict.
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
            switch try container.decode(String.self, forKey: .type) {
            case "http":
                self = .http(url: try container.decode(String.self, forKey: .url))
            default:
                self = .snapshot(json: "{}")
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
            let bool = try? container.decode(Bool.self) { value = bool } else {
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
