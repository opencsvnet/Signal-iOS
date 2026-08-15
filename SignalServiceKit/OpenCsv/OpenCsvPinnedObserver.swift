//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Pinned, read-only observation of exact transaction bytes. Each
/// provider gets its own ephemeral `OWSURLSession`; a pin failure cancels the
/// TLS challenge and is returned as failed evidence. There is deliberately no
/// fallback through an ordinary system-trust session.
public enum OpenCsvPinnedObserver {
    struct Profile: Sendable {
        let network: String
        let checkId: String
        let endpoint: String
        let host: String
        let certificateProfile: String
        let chainPins: Set<String>
    }

    private struct FetchResult: Sendable {
        let rawTransaction: Data?
        let evidence: OpenCsvObservationEvidence
    }

    public struct ObservationSet: Sendable {
        public let rawTransaction: Data
        public let evidence: [OpenCsvObservationEvidence]
    }

    // CA/intermediate certificates, never subscriber leaves. The overlapping
    // entries cover the currently served cross-chains and routine YR1/YR2
    // intermediate rotation.
    static let mempoolSpace = Profile(
        network: "signet",
        checkId: "mempool_space_signet",
        endpoint: "https://mempool.space/signet/api",
        host: "mempool.space",
        certificateProfile: "sectigo_r46",
        chainPins: [
            // Sectigo Public Server Authentication CA OV R36
            "6542d176bed50f193c0ce297ae44ecd8a0a86bec2ede682769344059b4e78530",
            // Sectigo Public Server Authentication Root R46, USERTrust cross-certificate
            "92f351bf3d54164dfa8dd8f9e1139d3150349786485d2b9eecd00e2971c1e6c5",
        ],
    )

    static let blockstream = Profile(
        network: "signet",
        checkId: "blockstream_signet",
        endpoint: "https://blockstream.info/signet/api",
        host: "blockstream.info",
        certificateProfile: "lets_encrypt_yr",
        chainPins: [
            // Let's Encrypt YR1 and YR2 active intermediates.
            "13949634d99cd6fd6aa80bc034fefacceb1969feef986586713ecdbb05758d3f",
            "238b85a0099c65b970477d5724f1a1d475ce5058cffe4efa8733899bdb863c47",
            // Root YR self-signed and the ISRG Root X1 cross-certificate.
            "e57b7e6f150c419102e8d5c055729ff967b9d1a829bf00cec89ca604ebf4a86f",
            "072639d0b140d5bffae16ad9c3f6cc6086040621f51ee61a6d46a8915c07cf76",
        ],
    )

    static let mempoolSpaceMainnet = Profile(
        network: "mainnet",
        checkId: "mempool_space_mainnet",
        endpoint: "https://mempool.space/api",
        host: "mempool.space",
        certificateProfile: "sectigo_r46",
        chainPins: mempoolSpace.chainPins,
    )

    static let blockstreamMainnet = Profile(
        network: "mainnet",
        checkId: "blockstream_mainnet",
        endpoint: "https://blockstream.info/api",
        host: "blockstream.info",
        certificateProfile: "lets_encrypt_yr",
        chainPins: blockstream.chainPins,
    )

    private static let profilesById = Dictionary(
        uniqueKeysWithValues: [
            mempoolSpace,
            blockstream,
            mempoolSpaceMainnet,
            blockstreamMainnet,
        ].map { ($0.checkId, $0) },
    )

    public static func observeTransaction(
        txid: String,
        policy: [OpenCsvObservationCheck],
    ) async throws -> ObservationSet {
        guard txid.count == 64, txid.allSatisfy(\.isHexDigit) else {
            throw OpenCsvClientError.ffi("invalid transaction id")
        }
        let profiles = try validatedProfiles(for: policy)
        let results = await withTaskGroup(of: FetchResult.self) { group in
            for profile in profiles {
                group.addTask { await fetch(txid: txid, profile: profile) }
            }
            var results: [FetchResult] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.evidence.checkId < $1.evidence.checkId }
        }
        guard let rawTransaction = results.lazy.compactMap(\.rawTransaction).first else {
            throw OpenCsvClientError.ffi("enabled pinned observers returned no transaction bytes")
        }
        return ObservationSet(
            rawTransaction: rawTransaction,
            evidence: results.map(\.evidence),
        )
    }

    static func validatedProfiles(
        for policy: [OpenCsvObservationCheck],
    ) throws -> [Profile] {
        let enabledRawChecks = policy.filter {
            $0.kind == .rawTransactionApi && $0.mode != .off
        }
        guard !enabledRawChecks.isEmpty else {
            throw OpenCsvClientError.ffi("no pinned raw-transaction observer is enabled")
        }
        let profiles = try enabledRawChecks.map { check in
            guard
                let profile = profilesById[check.id],
                check.endpoint == profile.endpoint,
                check.pinProfile == profile.certificateProfile,
                Set(check.chainFingerprintsSha256) == profile.chainPins
            else {
                throw OpenCsvClientError.ffi(
                    "unsupported or modified pinned observer: \(check.id)",
                )
            }
            return profile
        }
        guard Set(profiles.map(\.network)).count == 1 else {
            throw OpenCsvClientError.ffi("pinned observer policy mixes Bitcoin networks")
        }
        return profiles
    }

    private static func fetch(txid: String, profile: Profile) async -> FetchResult {
        let startedAtMs = millisecondsSinceEpoch()
        let chainFingerprints = AtomicValue<[String]>([], lock: .init())
        let securityPolicy = HttpSecurityPolicy(
            requiredChainCertificateSha256: profile.chainPins,
        )
        let session = OWSURLSession(
            securityPolicy: securityPolicy,
            configuration: OWSURLSession.defaultConfigurationWithoutCaching,
        )
        session.allowRedirects = false
        session.serverTrustEvaluationObserver = { host, fingerprints in
            guard host == profile.host else { return }
            chainFingerprints.set(fingerprints)
        }
        let requestUrl = URL(string: "\(profile.endpoint)/tx/\(txid)/raw")!
        var request = URLRequest(url: requestUrl)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let response = try await session.performRequest(
                request: request,
                maxResponseSize: 1_500_000,
                ignoreAppExpiry: false,
            )
            guard let data = response.responseBodyData, !data.isEmpty else {
                throw OpenCsvClientError.decode("observer returned an empty transaction")
            }
            let completedAtMs = millisecondsSinceEpoch()
            return FetchResult(
                rawTransaction: data,
                evidence: OpenCsvObservationEvidence(
                    checkId: profile.checkId,
                    endpoint: profile.endpoint,
                    result: "observed",
                    startedAtMs: startedAtMs,
                    completedAtMs: completedAtMs,
                    cachedAtMs: completedAtMs,
                    certificateProfile: profile.certificateProfile,
                    certificateChainFingerprintsSha256: chainFingerprints.get(),
                    rawTransactionHex: data.hexadecimalString,
                    detail: nil,
                ),
            )
        } catch {
            let completedAtMs = millisecondsSinceEpoch()
            return FetchResult(
                rawTransaction: nil,
                evidence: OpenCsvObservationEvidence(
                    checkId: profile.checkId,
                    endpoint: profile.endpoint,
                    result: "error",
                    startedAtMs: startedAtMs,
                    completedAtMs: completedAtMs,
                    cachedAtMs: completedAtMs,
                    certificateProfile: profile.certificateProfile,
                    certificateChainFingerprintsSha256: chainFingerprints.get(),
                    rawTransactionHex: nil,
                    detail: String(describing: error),
                ),
            )
        }
    }

    private static func millisecondsSinceEpoch() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
