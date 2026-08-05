//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Security

/// A simplified version of AFNetworking's AFSecurityPolicy.
public struct HttpSecurityPolicy {
    public static let signalCaPinned: HttpSecurityPolicy = .init(pinnedCertificates: [Certificates.load("signal-messenger", extension: "cer")])
    public static let systemDefault: HttpSecurityPolicy = .init()

    private let pinnedCertificates: [SecCertificate]?
    private let requiredChainCertificateSha256: Set<String>

    public init(
        pinnedCertificates: [SecCertificate]? = nil,
        requiredChainCertificateSha256: Set<String> = [],
    ) {
        self.pinnedCertificates = pinnedCertificates
        self.requiredChainCertificateSha256 = Set(
            requiredChainCertificateSha256.map(Self.normalizeFingerprint),
        )
    }

    public func evaluate(serverTrust: SecTrust, domain: String?) -> Bool {
        let policies = [SecPolicyCreateSSL(true, domain as CFString?)]

        guard SecTrustSetPolicies(serverTrust, policies as CFArray) == errSecSuccess else {
            Logger.error("the trust policy could not be set")
            return false
        }

        // use the default anchors if none were prvided in pinnedCertificates
        if let pinnedCertificates, !pinnedCertificates.isEmpty {
            guard SecTrustSetAnchorCertificates(serverTrust, pinnedCertificates as CFArray) == errSecSuccess else {
                Logger.error("the anchor certificates could not be set")
                return false
            }
        }

        guard Self.isValid(serverTrust: serverTrust) else {
            return false
        }
        guard !requiredChainCertificateSha256.isEmpty else {
            return true
        }
        let evaluatedChain = Set(Self.chainCertificateSha256(serverTrust: serverTrust))
        return !evaluatedChain.isDisjoint(with: requiredChainCertificateSha256)
    }

    /// SHA-256 fingerprints of the exact DER certificates in the evaluated
    /// trust path. Call only after normal trust evaluation; these are receipt
    /// evidence, never a substitute for hostname/date/chain validation.
    public static func chainCertificateSha256(serverTrust: SecTrust) -> [String] {
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            return []
        }
        return chain.map { certificate in
            let der = SecCertificateCopyData(certificate) as Data
            return Data(SHA256.hash(data: der)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func normalizeFingerprint(_ value: String) -> String {
        value.lowercased().filter(\.isHexDigit)
    }

    private static func isValid(serverTrust: SecTrust) -> Bool {
        guard SecTrustEvaluateWithError(serverTrust, nil) else {
            return false
        }
        var result: SecTrustResultType = .otherError // initialize to a value that would fail if SecTrustGetTrustResult doesn't overwrite it
        guard SecTrustGetTrustResult(serverTrust, &result) == errSecSuccess else {
            return false
        }
        return result == .unspecified || result == .proceed
    }
}
