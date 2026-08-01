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
        try db.write { tx in
            store.setVerdict(verified, blob: blob, attachmentId: 42, tx: tx)
            _ = try store.recordOutgoing(blob: Data([4, 5]), spends: ["coin1"], tx: tx)
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

    /// B3: sending 5 of 100 must render "5 sent", not the 95 change that
    /// the self-ingest credits back to us.
    @Test
    func outgoingVerdictShowsTheSentAmountNotTheChange() {
        let sent = OpenCsvVerdictRecord(
            sentAmount: 5,
            currency: "USD",
            assetId: "ab",
            date: Date(timeIntervalSince1970: 0),
        )
        #expect(sent.amount == 5)
        #expect(sent.direction == .outgoing)
        #expect(sent.isVerified)

        // What the old code did: derive the amount from the self-ingest,
        // which only ever credits change.
        let fromChangeCredits = OpenCsvVerdictRecord(
            verdict: OpenCsvVerdict(
                status: "verified",
                reason: nil,
                credits: [OpenCsvCredit(assetId: "ab", currency: "USD", amount: 95)],
                coins: nil,
                anchor: nil,
            ),
            date: Date(timeIntervalSince1970: 0),
        )
        #expect(fromChangeCredits.amount == 95, "sanity: this is the wrong number to show for a send")
        #expect(sent.amount != fromChangeCredits.amount)
    }

    /// A verified consignment crediting none of our coins is not a
    /// zero-value payment; rendering "+0" would assert a payment that did
    /// not happen to us.
    @Test
    func verifiedButUncreditedIsThirdPartyNotZero() {
        let record = OpenCsvVerdictRecord(
            verdict: OpenCsvVerdict(status: "verified", reason: nil, credits: [], coins: nil, anchor: nil),
            date: Date(timeIntervalSince1970: 0),
        )
        #expect(record.isVerified)
        #expect(record.direction == .thirdParty)
        #expect(record.amount == 0)

        let credited = OpenCsvVerdictRecord(
            verdict: OpenCsvVerdict(
                status: "verified",
                reason: nil,
                credits: [OpenCsvCredit(assetId: "ab", currency: "USD", amount: 7)],
                coins: nil,
                anchor: nil,
            ),
            date: Date(timeIntervalSince1970: 0),
        )
        #expect(credited.direction == .incoming)
    }

    /// B2: the record must outlive a failed delivery. It is cleared only in
    /// the transaction that inserts the message.
    @Test
    func pendingDeliverySurvivesUntilExplicitlyCleared() throws {
        let delivery = OpenCsvWalletStore.PendingDelivery(
            threadUniqueId: "thread-1",
            body: "OpenCSV consignment (9 bytes)",
            replayEntry: "o:1",
            amount: 5,
            currency: "USD",
            assetId: "ab",
            createdAt: Date(timeIntervalSince1970: 0),
        )
        try db.write { tx in
            _ = try store.recordOutgoing(blob: Data([1, 2, 3]), spends: ["coin1"], tx: tx)
            try store.addPendingDelivery(delivery, tx: tx)
        }
        db.read { tx in
            #expect(store.pendingDeliveries(tx: tx) == [delivery])
            // The bytes are referenced, not duplicated.
            #expect(store.blob(forReplayEntry: "o:1", tx: tx) == Data([1, 2, 3]))
            #expect(store.spentCoinIds(tx: tx) == ["coin1"])
        }

        try db.write { tx in try store.removePendingDelivery(id: delivery.id, tx: tx) }
        db.read { tx in #expect(store.pendingDeliveries(tx: tx).isEmpty) }
    }

    /// A delivery that can never succeed must stop being retried rather
    /// than looping on every foreground — but must not be discarded, since
    /// it is the only copy of a payment that already happened on-chain.
    @Test
    func exhaustedDeliveriesStopRetryingButAreKept() throws {
        var delivery = OpenCsvWalletStore.PendingDelivery(
            threadUniqueId: "gone",
            body: "b",
            replayEntry: "o:1",
            amount: 1,
            currency: nil,
            assetId: nil,
            createdAt: Date(timeIntervalSince1970: 0),
        )
        #expect(!delivery.hasExhaustedRetries)
        try db.write { tx in try store.addPendingDelivery(delivery, tx: tx) }

        delivery.attempts = OpenCsvWalletStore.maxDeliveryAttempts
        db.write { tx in store.updatePendingDelivery(delivery, tx: tx) }
        db.read { tx in
            let stored = store.pendingDeliveries(tx: tx)
            #expect(stored.count == 1, "an exhausted delivery must still be recoverable")
            #expect(stored.first?.hasExhaustedRetries == true)
        }
    }

    /// Two queued payments must both survive; the old whole-array rewrite
    /// discarded the rest of the queue on any decode failure.
    @Test
    func multipleDeliveriesAreIndependent() throws {
        let a = OpenCsvWalletStore.PendingDelivery(
            threadUniqueId: "t", body: "a", replayEntry: "o:1",
            amount: 1, currency: nil, assetId: nil, createdAt: Date(timeIntervalSince1970: 0),
        )
        let b = OpenCsvWalletStore.PendingDelivery(
            threadUniqueId: "t", body: "b", replayEntry: "o:2",
            amount: 2, currency: nil, assetId: nil, createdAt: Date(timeIntervalSince1970: 1),
        )
        try db.write { tx in
            try store.addPendingDelivery(a, tx: tx)
            try store.addPendingDelivery(b, tx: tx)
        }
        try db.write { tx in try store.removePendingDelivery(id: a.id, tx: tx) }
        db.read { tx in
            #expect(store.pendingDeliveries(tx: tx).map(\.id) == [b.id])
        }
    }

    /// S3: a decode failure must never read as "nothing is spent" — that
    /// would present already-spent coins as spendable.
    @Test
    func corruptSpentSetIsNotReadAsEmpty() throws {
        try db.write { tx in try store.addSpentCoinIds(["coin1", "coin2"], tx: tx) }
        db.read { tx in #expect(store.spentCoinIds(tx: tx) == ["coin1", "coin2"]) }
        // Re-adding is idempotent rather than duplicating.
        try db.write { tx in try store.addSpentCoinIds(["coin1"], tx: tx) }
        db.read { tx in #expect(store.spentCoinIds(tx: tx) == ["coin1", "coin2"]) }
    }

    /// An interrupted send must be distinguishable: with no txid nothing
    /// was published and the record is safe to drop; with one the coins are
    /// spent and the export is the only way to rebuild the payment.
    @Test
    func inFlightSendsTrackWhetherAnythingWasBroadcast() throws {
        var send = OpenCsvWalletStore.InFlightSend(
            exportJson: #"{"version":1}"#,
            threadUniqueId: "t",
            amount: 5,
            currency: "USD",
            assetId: "ab",
            createdAt: Date(timeIntervalSince1970: 0),
        )
        try db.write { tx in try store.upsertInFlightSend(send, tx: tx) }
        db.read { tx in
            #expect(store.inFlightSends(tx: tx).first?.txidHex == nil, "not broadcast yet")
        }

        send.txidHex = "beef"
        send.height = 100
        send.position = 2
        try db.write { tx in try store.upsertInFlightSend(send, tx: tx) }
        db.read { tx in
            let stored = store.inFlightSends(tx: tx)
            #expect(stored.count == 1, "updating must not duplicate the record")
            #expect(stored.first?.txidHex == "beef")
            #expect(stored.first?.height == 100)
            #expect(stored.first?.exportJson == #"{"version":1}"#)
        }

        try db.write { tx in try store.removeInFlightSend(id: send.id, tx: tx) }
        db.read { tx in #expect(store.inFlightSends(tx: tx).isEmpty) }
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


/// S9: the risky part of this feature is not any single function, it is
/// the transitions — detection agreeing across call sites, and a verdict
/// surviving the hop from "sent" to "rendered".
struct OpenCsvPipelineTransitionTest {
    /// A consignment whose filename was stripped is recognisable only by
    /// its body marker. Detection must agree wherever it is asked, or the
    /// download path ignores what the render path calls a payment.
    @Test
    func detectionAgreesWithAndWithoutTheFilename() {
        let markerBody = OpenCsvAttachmentDetector.outgoingBody(byteCount: 47_008)

        // Named file, no body: the download hook's historical case.
        #expect(OpenCsvAttachmentDetector.isConsignment(
            sourceFilename: OpenCsvAttachmentDetector.consignmentFilename,
            mimeType: "application/octet-stream",
            bodyText: nil,
        ))
        // Stripped filename, marker body: recognised only if the body is
        // resolved — the inconsistency that let one path skip it.
        #expect(OpenCsvAttachmentDetector.isConsignment(
            sourceFilename: nil,
            mimeType: "application/octet-stream",
            bodyText: markerBody,
        ))
        #expect(!OpenCsvAttachmentDetector.isConsignment(
            sourceFilename: nil,
            mimeType: "application/octet-stream",
            bodyText: nil,
        ))
    }

    /// The verdict a send writes must be the one the bubble renders: same
    /// direction, and the amount sent rather than the change credited.
    @Test
    func sentVerdictSurvivesToTheRenderShape() throws {
        let delivery = OpenCsvWalletStore.PendingDelivery(
            threadUniqueId: "t",
            body: OpenCsvAttachmentDetector.outgoingBody(byteCount: 10),
            replayEntry: "o:1",
            amount: 5,
            currency: "USD",
            assetId: "ab",
            createdAt: Date(timeIntervalSince1970: 0),
        )
        let record = OpenCsvVerdictRecord(
            sentAmount: delivery.amount,
            currency: delivery.currency,
            assetId: delivery.assetId,
            date: Date(timeIntervalSince1970: 0),
        )

        let db = InMemoryDB()
        let store = OpenCsvWalletStore(keychainStorage: MockKeychainStorage())
        db.write { tx in store.setVerdict(record, blob: nil, attachmentId: 7, tx: tx) }
        db.read { tx in
            let rendered = store.verdict(attachmentId: 7, tx: tx)
            #expect(rendered?.direction == .outgoing)
            #expect(rendered?.amount == 5, "the bubble must show what was sent, not the change")
            #expect(rendered?.currency == "USD")
        }

        // An outgoing verdict carries no replay blob: the send path already
        // recorded the consignment under its own entry, and storing it
        // twice was the duplication this replaced.
        db.read { tx in #expect(store.replayBlobs(tx: tx).isEmpty) }
    }
}
