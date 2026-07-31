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

    /// Publish a 64-byte anchor record (hex), returning where it anchored.
    func publishAnchor(recordHex: String) async throws -> OpenCsvAnchorRef
}

/// Errors from the remote anchor provider.
public enum OpenCsvAnchorProviderError: Error {
    /// No anchor server URL is configured.
    case notConfigured
    /// The server responded with a non-200 status.
    case serverError(statusCode: Int, body: String)
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

    public func publishAnchor(recordHex: String) async throws -> OpenCsvAnchorRef {
        var request = URLRequest(url: baseURL.appendingPathComponent("anchor"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["record": recordHex])
        let (data, response) = try await urlSession.data(for: request)
        try Self.checkStatus(response: response, data: data)
        return try JSONDecoder().decode(OpenCsvAnchorRef.self, from: data)
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

    public func publishAnchor(recordHex: String) async throws -> OpenCsvAnchorRef {
        throw OpenCsvAnchorProviderError.notConfigured
    }
}
