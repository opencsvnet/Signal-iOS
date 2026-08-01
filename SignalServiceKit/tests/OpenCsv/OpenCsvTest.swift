//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Testing

@testable import SignalServiceKit

struct OpenCsvAttachmentDetectorTest {
    @Test
    func detectsByFilename() {
        #expect(OpenCsvAttachmentDetector.isConsignment(
            sourceFilename: "opencsv-consignment.bin",
            mimeType: "application/octet-stream",
            bodyText: nil,
        ))
        #expect(OpenCsvAttachmentDetector.isConsignment(
            sourceFilename: "OpenCSV-Consignment.BIN",
            mimeType: nil,
            bodyText: nil,
        ))
        #expect(!OpenCsvAttachmentDetector.isConsignment(
            sourceFilename: "vacation.jpg",
            mimeType: "image/jpeg",
            bodyText: nil,
        ))
    }

    @Test
    func detectsByBodyMarker() {
        #expect(OpenCsvAttachmentDetector.isConsignment(
            sourceFilename: nil,
            mimeType: "application/octet-stream",
            bodyText: "OpenCSV consignment (56041 bytes)",
        ))
        // Marker present but a typed attachment: not a consignment.
        #expect(!OpenCsvAttachmentDetector.isConsignment(
            sourceFilename: nil,
            mimeType: "image/jpeg",
            bodyText: "OpenCSV consignment (2 coins)",
        ))
        #expect(!OpenCsvAttachmentDetector.isConsignment(
            sourceFilename: nil,
            mimeType: nil,
            bodyText: "hello there",
        ))
    }

    @Test
    func outgoingBodyCarriesMarker() {
        let body = OpenCsvAttachmentDetector.outgoingBody(byteCount: 123)
        #expect(body.hasPrefix(OpenCsvAttachmentDetector.bodyMarkerPrefix))
        #expect(body.contains("123"))
    }

    @Test
    func addressAnnouncementRoundTrip() {
        let key = String(repeating: "ab", count: 32)
        let announcement = OpenCsvAttachmentDetector.addressAnnouncement(owner: key)
        #expect(OpenCsvAttachmentDetector.parseAddress(fromBody: announcement) == key)
        // As a second line of a consignment body (the payment send path).
        let body = OpenCsvAttachmentDetector.outgoingBody(byteCount: 9) + "\n" + announcement
        #expect(OpenCsvAttachmentDetector.parseAddress(fromBody: body) == key)
        // Uppercase hex normalizes; junk is rejected.
        #expect(OpenCsvAttachmentDetector.parseAddress(
            fromBody: OpenCsvAttachmentDetector.addressAnnouncement(owner: key.uppercased()),
        ) == key)
        #expect(OpenCsvAttachmentDetector.parseAddress(fromBody: "OpenCSV address: zz") == nil)
        #expect(OpenCsvAttachmentDetector.parseAddress(fromBody: "hello") == nil)
        #expect(OpenCsvAttachmentDetector.parseAddress(fromBody: nil) == nil)
    }
}

struct OpenCsvVerdictParsingTest {
    /// The exact JSON shape `opencsv-ffi`'s `opencsv_verify_consignment`
    /// returns on success.
    @Test
    func decodesVerifiedVerdict() throws {
        let json = """
        {"status":"verified","credits":[{"asset_id":"ab12","currency":"USD","amount":100}],
         "coins":[{"id":"c0ffee","asset_id":"ab12","currency":"USD","value":100,"unspent":true}],
         "anchor":{"height":4,"position":0}}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let verdict = try decoder.decode(OpenCsvVerdict.self, from: Data(json.utf8))
        #expect(verdict.isVerified)
        #expect(verdict.credits?.first?.amount == 100)
        #expect(verdict.credits?.first?.currency == "USD")
        #expect(verdict.coins?.first?.unspent == true)
        #expect(verdict.anchor?.height == 4)

        let record = OpenCsvVerdictRecord(verdict: verdict, date: Date(timeIntervalSince1970: 0))
        #expect(record.isVerified)
        #expect(record.amount == 100)
        #expect(record.currency == "USD")
    }

    @Test
    func decodesRejectedVerdict() throws {
        let json = #"{"status":"rejected","reason":"InsufficientConfirmations { have: 1, required: 6 }"}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let verdict = try decoder.decode(OpenCsvVerdict.self, from: Data(json.utf8))
        #expect(!verdict.isVerified)
        let record = OpenCsvVerdictRecord(verdict: verdict, date: Date(timeIntervalSince1970: 0))
        #expect(!record.isVerified)
        #expect(record.amount == 0)
        #expect(record.reason?.contains("InsufficientConfirmations") == true)
    }
}

struct OpenCsvWalletStoreTest {
    private let db = InMemoryDB()
    private let store = OpenCsvWalletStore(keychainStorage: MockKeychainStorage())

    @Test
    func secretsRoundTripThroughKeychain() throws {
        #expect(try store.walletSecrets() == nil)
        try store.setWalletSecrets(#"{"version":1}"#)
        #expect(try store.walletSecrets() == #"{"version":1}"#)
    }

    @Test
    func verdictAndReplayRoundTrip() throws {
        let verified = OpenCsvVerdictRecord(
            verdict: OpenCsvVerdict(
                status: "verified",
                reason: nil,
                credits: [OpenCsvCredit(assetId: "ab", currency: "USD", amount: 7)],
                coins: nil,
                anchor: nil,
            ),
            date: Date(timeIntervalSince1970: 0),
        )
        let blob = Data([1, 2, 3])
        db.write { tx in
            store.setVerdict(verified, blob: blob, attachmentId: 42, tx: tx)
            store.recordOutgoing(blob: Data([4, 5]), spends: ["coin1"], tx: tx)
        }
        db.read { tx in
            #expect(store.verdict(attachmentId: 42, tx: tx) == verified)
            #expect(store.verdict(attachmentId: 43, tx: tx) == nil)
            let replay = store.replayBlobs(tx: tx)
            #expect(replay.map(\.entry) == ["a:42", "o:1"])
            #expect(replay.map(\.blob) == [blob, Data([4, 5])])
            #expect(store.spentCoinIds(tx: tx) == ["coin1"])
        }
        // Rejected verdicts store no replay blob.
        let rejected = OpenCsvVerdictRecord(
            verdict: OpenCsvVerdict(status: "rejected", reason: "x", credits: nil, coins: nil, anchor: nil),
            date: Date(timeIntervalSince1970: 0),
        )
        db.write { tx in
            store.setVerdict(rejected, blob: Data([9]), attachmentId: 50, tx: tx)
        }
        db.read { tx in
            #expect(store.replayBlobs(tx: tx).count == 2)
        }
    }

    @Test
    func anchorServerUrlSetting() {
        db.write { tx in
            store.setAnchorServerUrl("http://192.168.1.20:8787", tx: tx)
        }
        db.read { tx in
            #expect(store.anchorServerUrl(tx: tx)?.absoluteString == "http://192.168.1.20:8787")
        }
        db.write { tx in
            store.setAnchorServerUrl(nil, tx: tx)
        }
        db.read { tx in
            #expect(store.anchorServerUrl(tx: tx) == nil)
        }
    }
}

/// Exercises the real Rust FFI linked into SignalServiceKit.
struct OpenCsvClientFfiTest {
    @Test
    func createOpenAndQueryWallet() throws {
        let secrets = try OpenCsvWallet.createSecrets()
        let wallet = try OpenCsvWallet(secretsJson: secrets)
        #expect(wallet.owners.count == 1)
        #expect(wallet.owners[0].count == 64)
        #expect(try wallet.balance().isEmpty)
        #expect(try wallet.coins().isEmpty)

        // Reopening the same secrets yields the same owner key.
        let reopened = try OpenCsvWallet(secretsJson: try wallet.secretsJson())
        #expect(reopened.owners == wallet.owners)
    }

    @Test
    func rejectsGarbageInputs() {
        #expect(throws: OpenCsvClientError.self) {
            _ = try OpenCsvWallet(secretsJson: "not json")
        }
        #expect(throws: OpenCsvClientError.self) {
            let wallet = try OpenCsvWallet(secretsJson: OpenCsvWallet.createSecrets())
            _ = try wallet.verify(
                blob: Data([0, 1, 2]),
                snapshotJson: #"{"tip_height":0,"entries":[]}"#,
                requiredConfirmations: 6,
            )
        }
    }

    @Test
    func auditOfEmptyChainIsZero() throws {
        let assetId = String(repeating: "ab", count: 32)
        let supply = try OpenCsvWallet.audit(
            assetIdHex: assetId,
            snapshotJson: #"{"tip_height":0,"entries":[]}"#,
        )
        #expect(supply == 0)
    }
}
