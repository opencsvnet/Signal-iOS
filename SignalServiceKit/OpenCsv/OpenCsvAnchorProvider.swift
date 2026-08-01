//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// The wallet's view of the anchor chain: fetch the whole anchor-log
/// snapshot, and publish a new anchor record. In the prototype this is the
/// demo anchor server (`opencsv-anchor-server`); a production backend would
/// be a Bitcoin indexer plus transaction broadcast.
public protocol OpenCsvAnchorProvider {
    /// The whole anchor-log view as the snapshot JSON `opencsv-ffi`
    /// consumes (`{"tip_height":N,"entries":[...]}`).
    func fetchSnapshotJson() async throws -> String

    /// Reserve a transaction context to bind the next anchor record to, or
    /// `nil` when the backend lets callers choose freely (demo chains).
    ///
    /// Real chains derive the context from the anchor transaction's funding
    /// outpoint, so the service must reserve that outpoint before the
    /// record exists — and the anchor must then spend exactly it.
    func reserveContext() async throws -> String?

    /// Publish a 64-byte anchor record (hex) under `ctxHex`, returning
    /// where it anchored (after confirmation, on real chains).
    func publishAnchor(recordHex: String, ctxHex: String) async throws -> OpenCsvAnchorRef
}

/// Errors from the remote anchor provider.
public enum OpenCsvAnchorProviderError: Error {
    /// No anchor server URL is configured.
    case notConfigured
    /// The server responded with a non-200 status.
    case serverError(statusCode: Int, body: String)
    /// The anchor transaction was broadcast but not mined in time; the
    /// pending transaction can be finalized later once it confirms.
    case anchorTimedOut(txid: String)
}

/// An anchor provider backed by `opencsv-anchor-server` at a user-configured
/// base URL (`GET /snapshot`, `POST /anchor`). No URL is hardcoded anywhere:
/// the URL comes from wallet settings.
public final class RemoteOpenCsvAnchorProvider: OpenCsvAnchorProvider {
    private let baseURL: URL
    private let urlSession: URLSession

    public init(baseURL: URL, urlSession: URLSession = URLSession(configuration: .ephemeral)) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func fetchSnapshotJson() async throws -> String {
        let (data, response) = try await urlSession.data(from: baseURL.appendingPathComponent("snapshot"))
        try Self.checkStatus(response: response, data: data)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OpenCsvAnchorProviderError.serverError(statusCode: 200, body: "non-UTF-8 snapshot")
        }
        return json
    }

    private struct PublishReply: Codable {
        let txid: String
        // Present when the backend anchors immediately (demo file chain);
        // absent on real chains until the transaction is mined.
        let height: UInt64?
        let position: UInt32?
    }

    private struct AnchorStatus: Codable {
        let confirmed: Bool
        let height: UInt64?
        let position: UInt32?
    }

    public func reserveContext() async throws -> String? {
        struct ContextReply: Codable { let ctx: String }
        var request = URLRequest(url: baseURL.appendingPathComponent("anchor/context"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await urlSession.data(for: request)
        // A missing route means a demo-era server that lets the caller
        // choose the context; any other failure is real and must surface.
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return nil
        }
        try Self.checkStatus(response: response, data: data)
        return try JSONDecoder().decode(ContextReply.self, from: data).ctx
    }

    public func publishAnchor(recordHex: String, ctxHex: String) async throws -> OpenCsvAnchorRef {
        var request = URLRequest(url: baseURL.appendingPathComponent("anchor"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["record": recordHex, "ctx": ctxHex])
        let (data, response) = try await urlSession.data(for: request)
        try Self.checkStatus(response: response, data: data)
        let reply = try JSONDecoder().decode(PublishReply.self, from: data)
        if let height = reply.height, let position = reply.position {
            return OpenCsvAnchorRef(txid: reply.txid, height: height, position: position)
        }
        return try await waitForConfirmation(txid: reply.txid)
    }

    /// Poll until the anchor transaction is mined. Blocks arrive in
    /// seconds on mutinynet and ~10 minutes on signet/mainnet.
    private func waitForConfirmation(txid: String) async throws -> OpenCsvAnchorRef {
        let pollSeconds: UInt64 = 10
        let maxPolls = 270 // 45 minutes
        Logger.info("anchor \(txid) broadcast; waiting for confirmation")
        for _ in 0..<maxPolls {
            try await Task.sleep(nanoseconds: pollSeconds * NSEC_PER_SEC)
            let url = baseURL.appendingPathComponent("anchor").appendingPathComponent(txid)
            let (data, response) = try await urlSession.data(from: url)
            try Self.checkStatus(response: response, data: data)
            let status = try JSONDecoder().decode(AnchorStatus.self, from: data)
            if status.confirmed, let height = status.height, let position = status.position {
                Logger.info("anchor \(txid) confirmed at height \(height)")
                return OpenCsvAnchorRef(txid: txid, height: height, position: position)
            }
        }
        throw OpenCsvAnchorProviderError.anchorTimedOut(txid: txid)
    }

    private static func checkStatus(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenCsvAnchorProviderError.serverError(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8) ?? "",
            )
        }
    }
}

/// A fixed-snapshot provider for tests and for demo mode when no anchor
/// server is configured. Publishing is not supported.
public final class DemoOpenCsvAnchorProvider: OpenCsvAnchorProvider {
    private let snapshotJson: String

    /// - Parameter snapshotJson: a full snapshot document; defaults to an
    ///   empty chain.
    public init(snapshotJson: String = #"{"tip_height":0,"entries":[]}"#) {
        self.snapshotJson = snapshotJson
    }

    public func fetchSnapshotJson() async throws -> String {
        snapshotJson
    }

    public func reserveContext() async throws -> String? {
        nil
    }

    public func publishAnchor(recordHex: String, ctxHex: String) async throws -> OpenCsvAnchorRef {
        throw OpenCsvAnchorProviderError.notConfigured
    }
}
