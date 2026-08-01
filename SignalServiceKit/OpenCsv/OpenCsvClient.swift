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

    public var isVerified: Bool { status == "verified" }

    public init(status: String, reason: String?, credits: [OpenCsvCredit]?, coins: [OpenCsvCoin]?, anchor: Anchor?) {
        self.status = status
        self.reason = reason
        self.credits = credits
        self.coins = coins
        self.anchor = anchor
    }
}

/// Result of a `prove*` call: publish `anchorRecordHex` under `ctxHex`,
/// then finalize. On real chains the anchoring service supplies the
/// context instead — see `OpenCsvWallet.rebind`.
public struct OpenCsvProved: Codable, Equatable {
    public let pendingId: UInt64
    public let anchorRecordHex: String
    public let ctxHex: String
    public let spends: [String]
}

/// Where a published anchor record landed, per the anchor server.
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
        try Self.take(blob.withUnsafeBytes { bytes in
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

    /// Prove an issuer mint (this wallet must hold the issuer key).
    public func proveMint(assetIdHex: String, toOwnerHex: String, amounts: [UInt64]) throws -> OpenCsvProved {
        let amountsJson = try Self.encodeJson(amounts)
        return try Self.take(assetIdHex.withCString { asset in
            toOwnerHex.withCString { owner in
                amountsJson.withCString { amounts in
                    opencsv_prove_mint(handle, asset, owner, amounts)
                }
            }
        })
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

    /// Create an issuer identity for a 3-letter currency code; persist
    /// secrets afterwards.
    public func initIssuer(currency: String) throws -> String {
        let asset: AssetId = try Self.take(currency.withCString { opencsv_wallet_init_issuer(handle, $0) })
        return asset.assetId
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
