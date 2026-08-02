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

    /// The v1 single-server setting must survive as an indexer entry —
    /// but one indexer is not a cross-check, and the code says so.
    @Test
    func indexerListMigratesFromTheSingleAnchorServer() throws {
        db.read { tx in #expect(store.indexerUrls(tx: tx).isEmpty) }

        db.write { tx in store.setAnchorServerUrl("http://one.example:8787", tx: tx) }
        db.read { tx in
            #expect(store.indexerUrls(tx: tx) == ["http://one.example:8787"], "v1 config must not be lost")
        }

        // An explicit list wins over the migrated single entry.
        try db.write { tx in
            try store.setIndexerUrls(["http://a.example", "http://b.example", "http://c.example"], tx: tx)
        }
        db.read { tx in #expect(store.indexerUrls(tx: tx).count == 3) }

        // Empties are not indexers.
        try db.write { tx in try store.setIndexerUrls(["http://a.example", ""], tx: tx) }
        db.read { tx in #expect(store.indexerUrls(tx: tx) == ["http://a.example"]) }
    }

    @Test
    func chainViewDefaultsAreExplicit() throws {
        db.read { tx in
            #expect(store.network(tx: tx) == "signet", "a prototype must not default to mainnet")
            #expect(store.spvPeers(tx: tx).isEmpty)
        }
        try db.write { tx in try store.setSpvPeers(["node.example:38333"], tx: tx) }
        db.read { tx in #expect(store.spvPeers(tx: tx) == ["node.example:38333"]) }
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

struct OpenCsvChainViewTest {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: - SPV verdicts (opencsv_cbf_verify_anchor JSON shapes)

    @Test
    func decodesSpvConfirmedVerdict() throws {
        let json = """
        {"status":"confirmed","ctx_hex":"aa","block_hash_hex":"bb","confirmations":9,
         "filter_diagnostic":false,"tip_height":120}
        """
        let verdict = try decoder.decode(OpenCsvChainView.SpvVerdict.self, from: Data(json.utf8))
        #expect(verdict.isConfirmed)
        #expect(verdict.confirmations == 9)
        #expect(verdict.blockHashHex == "bb")
    }

    /// The doctrine at the top of OpenCsvChainView: `filter_diagnostic` is
    /// never evidence. A confirmed verdict stays confirmed with the flag
    /// false, and a not_present verdict stays not_present with it true.
    @Test
    func filterDiagnosticIsPresentButNeverEvidence() throws {
        let confirmed = try decoder.decode(
            OpenCsvChainView.SpvVerdict.self,
            from: Data(#"{"status":"confirmed","confirmations":6,"filter_diagnostic":false}"#.utf8),
        )
        #expect(confirmed.isConfirmed)
        #expect(confirmed.filterDiagnostic == false)

        let absent = try decoder.decode(
            OpenCsvChainView.SpvVerdict.self,
            from: Data(#"{"status":"not_present","reason":"txid_mismatch","filter_diagnostic":true}"#.utf8),
        )
        #expect(!absent.isConfirmed)
        #expect(absent.filterDiagnostic == true)
    }

    @Test
    func decodesSpvNotPresentVerdict() throws {
        // Sibling detail keys (claimed/actual) must not break decoding.
        let json = """
        {"status":"not_present","reason":"txid_mismatch",
         "claimed_hex":"aa","actual_hex":"bb","tip_height":50}
        """
        let verdict = try decoder.decode(OpenCsvChainView.SpvVerdict.self, from: Data(json.utf8))
        #expect(!verdict.isConfirmed)
        #expect(verdict.reason == "txid_mismatch")
    }

    @Test
    func decodesSpvInsufficientConfirmations() throws {
        let json = #"{"status":"insufficient_confirmations","have":2,"required":6}"#
        let verdict = try decoder.decode(OpenCsvChainView.SpvVerdict.self, from: Data(json.utf8))
        #expect(!verdict.isConfirmed)
        #expect(verdict.have == 2)
        #expect(verdict.required == 6)
    }

    // MARK: - Cross-check verdicts

    @Test
    func decodesCrossCheckVerdicts() throws {
        let verified = try decoder.decode(
            OpenCsvChainView.CrossCheckVerdict.self,
            from: Data(#"{"status":"verified","tip_height":9}"#.utf8),
        )
        #expect(verified.isVerified)
        #expect(!verified.isTipDisagreement)

        let rejected = try decoder.decode(
            OpenCsvChainView.CrossCheckVerdict.self,
            from: Data(#"{"status":"rejected","reason":"NullifierConflict"}"#.utf8),
        )
        #expect(!rejected.isVerified)
        #expect(rejected.reason == "NullifierConflict")

        // A tip disagreement arrives as the error shape and must decode as
        // a verdict (not be thrown away) so callers can say why.
        let disagreement = try decoder.decode(
            OpenCsvChainView.CrossCheckVerdict.self,
            from: Data(#"{"error":"backends disagree","kind":"tip_disagreement","tips":[10,12]}"#.utf8),
        )
        #expect(disagreement.isTipDisagreement)
        #expect(disagreement.tips == [10, 12])
        #expect(!disagreement.isVerified)
    }

    // MARK: - Scan verdicts (opencsv_scan_verify JSON shapes)

    @Test
    func decodesScanVerdicts() throws {
        let verified = try decoder.decode(
            OpenCsvChainView.ScanVerdict.self,
            from: Data("""
            {"status":"verified","coins":[{"id":"aa","asset_id":"bb","value":5,"owner":"cc"}],
             "anchor":{"height":3,"position":0},"confirmations":7,"tip_height":10}
            """.utf8),
        )
        #expect(verified.isVerified)
        #expect(verified.confirmations == 7)

        let rejected = try decoder.decode(
            OpenCsvChainView.ScanVerdict.self,
            from: Data(#"{"status":"rejected","reason":"NullifierConflict","tip_height":10}"#.utf8),
        )
        #expect(!rejected.isVerified)
        #expect(rejected.reason == "NullifierConflict")
    }

    // MARK: - Backend Codable

    @Test
    func backendCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let http = try JSONDecoder().decode(
            OpenCsvChainView.Backend.self,
            from: try encoder.encode(OpenCsvChainView.Backend.http(url: "http://indexer:8080")),
        )
        guard case .http(let url) = http else {
            Issue.record("http backend did not survive the round trip")
            return
        }
        #expect(url == "http://indexer:8080")

        let snapshot = try JSONDecoder().decode(
            OpenCsvChainView.Backend.self,
            from: try encoder.encode(OpenCsvChainView.Backend.snapshot(json: "{}")),
        )
        guard case .snapshot(let json) = snapshot else {
            Issue.record("snapshot backend did not survive the round trip")
            return
        }
        #expect(json == "{}")
    }

    @Test
    func backendUnknownTypeThrows() {
        // An unrecognized backend must fail loudly, never silently decode
        // as an empty snapshot that weakens the cross-check.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                OpenCsvChainView.Backend.self,
                from: Data(#"{"type":"carrier-pigeon"}"#.utf8),
            )
        }
    }

    // MARK: - Snapshot → SPV claim

    @Test
    func anchorClaimFromSnapshot() throws {
        let snapshot = """
        {"tip_height":10,"entries":[
          {"height":3,"position":0,"txid":"aa11","ctx":"cc","record":"dd"},
          {"height":7,"position":2,"txid":"bb22","ctx":"ee","record":"ff"}]}
        """
        let anchor = try decoder.decode(
            OpenCsvVerdict.Anchor.self,
            from: Data(#"{"height":7,"position":2}"#.utf8),
        )
        let claim = OpenCsvChainView.anchorClaim(
            fromSnapshotJson: snapshot,
            anchor: anchor,
            requiredConfirmations: 6,
        )
        #expect(claim?.txidHex == "bb22")
        #expect(claim?.recordHex == "ff")
        #expect(claim?.height == 7)
        #expect(claim?.position == 2)
        #expect(claim?.requiredConfirmations == 6)

        // No entry at the claimed location: no claim, never a guess.
        let missing = try decoder.decode(
            OpenCsvVerdict.Anchor.self,
            from: Data(#"{"height":9,"position":0}"#.utf8),
        )
        #expect(OpenCsvChainView.anchorClaim(
            fromSnapshotJson: snapshot,
            anchor: missing,
            requiredConfirmations: 6,
        ) == nil)
    }

    // MARK: - Decision ladder

    @Test
    func chainViewPlanPrefersTheStrongestConfiguredView() {
        // Self-scan wins whenever peers exist, regardless of indexers.
        #expect(OpenCsvPayments.chainViewPlan(peerCount: 1, indexerCount: 0) == .selfScan)
        #expect(OpenCsvPayments.chainViewPlan(peerCount: 2, indexerCount: 5) == .selfScan)
        // Cross-check needs at least two independent indexers.
        #expect(OpenCsvPayments.chainViewPlan(peerCount: 0, indexerCount: 2) == .crossCheck)
        // One indexer is not a cross-check; zero of anything is a demo.
        #expect(OpenCsvPayments.chainViewPlan(peerCount: 0, indexerCount: 1) == .singleSnapshot)
        #expect(OpenCsvPayments.chainViewPlan(peerCount: 0, indexerCount: 0) == .singleSnapshot)
    }

    /// A lagging chain view must never produce a final verdict — found
    /// live when a payment message beat the scan index by seconds and was
    /// permanently rejected with AnchorNotFound.
    @Test
    func chainLagReasonsAreNeverFinal() {
        #expect(OpenCsvPayments.isChainLagReason("AnchorNotFound"))
        #expect(OpenCsvPayments.isChainLagReason("InsufficientConfirmations { have: 2, required: 6 }"))
        #expect(!OpenCsvPayments.isChainLagReason("NullifierConflict"))
        #expect(!OpenCsvPayments.isChainLagReason("NoOwnedOutput"))
        #expect(!OpenCsvPayments.isChainLagReason(nil))
    }

    // MARK: - Verdict record compatibility

    @Test
    func verdictRecordWithoutChainViewStillDecodes() throws {
        // Records persisted before the chainView field existed must load.
        let legacy = """
        {"status":"verified","amount":5,"currency":"USD","assetId":"ab",
         "direction":"incoming","verifiedAt":0}
        """
        let record = try JSONDecoder().decode(OpenCsvVerdictRecord.self, from: Data(legacy.utf8))
        #expect(record.isVerified)
        #expect(record.chainView == nil)
    }

    @Test
    func verdictRecordCarriesChainViewThrough() throws {
        var verdict = try decoder.decode(
            OpenCsvVerdict.self,
            from: Data(#"{"status":"verified","credits":[],"anchor":{"height":1,"position":0}}"#.utf8),
        )
        verdict.chainView = "self-scan"
        let record = OpenCsvVerdictRecord(verdict: verdict, date: Date(timeIntervalSince1970: 0))
        #expect(record.chainView == "self-scan")

        let reloaded = try JSONDecoder().decode(
            OpenCsvVerdictRecord.self,
            from: try JSONEncoder().encode(record),
        )
        #expect(reloaded.chainView == "self-scan")
    }
}

/// Chain-view calls against the real FFI binary — offline, instant: they
/// pin symbol linkage, request-key encoding, and error mapping without
/// touching the network.
struct OpenCsvChainViewFfiTest {
    /// The FFI validates the consignment's encoding before consulting the
    /// scan registration (live-verified check order), so garbage bytes
    /// surface as an `ffi` error — never a "rejected" verdict a caller
    /// might persist as final.
    @Test
    func scanVerifyGarbageConsignmentIsAnErrorNotARejection() throws {
        let wallet = try OpenCsvWallet(secretsJson: OpenCsvWallet.createSecrets())
        do {
            _ = try OpenCsvChainView.scanVerify(wallet: wallet, consignment: Data([1, 2, 3]))
            Issue.record("garbage bytes must not produce a verdict")
        } catch let OpenCsvClientError.ffi(message) {
            #expect(message.contains("consignment"))
        }
    }

    /// An unknown network fails at config parse, before any peer is
    /// dialed. If the Swift request encoding ever drifted from the ABI's
    /// snake_case keys, this would fail with "missing field" instead.
    @Test
    func scanSyncRejectsAnUnknownNetworkAtConfigParse() {
        let config = OpenCsvChainView.ScanSyncConfig(
            network: "marsnet",
            peers: ["127.0.0.1:1"],
            cacheDir: NSTemporaryDirectory() + "opencsv-scan-config-test",
            fromHeight: 0,
            requiredConfirmations: 6,
        )
        do {
            _ = try OpenCsvChainView.scanSync(config: config)
            Issue.record("an unknown network must be rejected")
        } catch let OpenCsvClientError.ffi(message) {
            #expect(message.contains("marsnet") || message.lowercased().contains("network"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// Serverless crediting's precondition, pinned: exporting before any
    /// sync is an infrastructure error (the crediting path falls back to
    /// server/cache), with the exact string the FFI asserts in its own
    /// tests. Skipped in live-regtest runs, where the scan registration
    /// this asserts the absence of legitimately exists in-process.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCSV_REGTEST"] != "1"))
    func exportSnapshotBeforeAnySyncThrowsNoScanRegistered() {
        do {
            _ = try OpenCsvChainView.exportScanSnapshot()
            Issue.record("export without a sync must throw")
        } catch let OpenCsvClientError.ffi(message) {
            #expect(message.contains("no scan registered"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func spvVerifyAnchorConfigErrorsSurfaceAsFfiErrors() {
        let config = OpenCsvChainView.SpvConfig(
            network: "marsnet",
            peers: ["127.0.0.1:1"],
            cacheDir: NSTemporaryDirectory() + "opencsv-cbf-config-test",
            timeoutMs: 500,
        )
        let claim = OpenCsvChainView.AnchorClaim(
            recordHex: String(repeating: "0", count: 128),
            txidHex: String(repeating: "1", count: 64),
            height: 1,
            position: 0,
            requiredConfirmations: 1,
        )
        #expect(throws: OpenCsvClientError.self) {
            _ = try OpenCsvChainView.verifyAnchor(config: config, claim: claim)
        }
    }
}

/// Live end-to-end against a host bitcoind: the whole app-side pipeline —
/// Swift config encoding → FFI → P2P handshake → header/filter sync →
/// on-disk occurrence index → registered scan verify. Requires
/// `bitcoind -regtest -blockfilterindex=1 -peerblockfilters=1` listening
/// on 127.0.0.1:18444; run with TEST_RUNNER_OPENCSV_REGTEST=1.
struct OpenCsvScanRegtestTest {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCSV_REGTEST"] == "1"))
    func syncsTheScanIndexFromALiveRegtestNode() throws {
        let cacheDir = NSTemporaryDirectory() + "opencsv-scan-regtest-\(UUID().uuidString)"
        let result = try OpenCsvChainView.scanSync(config: .init(
            network: "regtest",
            peers: ["127.0.0.1:18444"],
            cacheDir: cacheDir,
            fromHeight: 1,
            requiredConfirmations: 1,
        ))
        #expect(result.tipHeight > 0)
        #expect(result.filtersBytes > 0, "a real sync walks real filter bytes")
        // Live diagnostic for the log: the honest bandwidth numbers.
        print(
            "OPENCSV_REGTEST scan sync: tip \(result.tipHeight), "
            + "anchors \(result.anchors), filters \(result.filtersBytes) B, "
            + "blocks \(result.blocksBytes) B",
        )

        // When the host chain carries marker-bearing anchor transactions
        // (OPENCSV_REGTEST_MIN_ANCHORS says how many), the filter walk
        // must discover them — that is the whole design.
        let env = ProcessInfo.processInfo.environment
        if let minAnchors = env["OPENCSV_REGTEST_MIN_ANCHORS"].flatMap(UInt64.init) {
            #expect(result.anchors >= minAnchors, "the filter walk missed the marker anchor(s)")
            #expect(result.blocksBytes > 0, "an anchor day downloads its block")
        }

        // With the index registered, a garbage consignment still fails on
        // its own defects (encoding is checked first), as an error — never
        // as a persistable verdict.
        let wallet = try OpenCsvWallet(secretsJson: OpenCsvWallet.createSecrets())
        #expect(throws: OpenCsvClientError.self) {
            _ = try OpenCsvChainView.scanVerify(wallet: wallet, consignment: Data([1, 2, 3]))
        }

        // A second sync resumes from the synced tip: no filter re-walk.
        let resumed = try OpenCsvChainView.scanSync(config: .init(
            network: "regtest",
            peers: ["127.0.0.1:18444"],
            cacheDir: cacheDir,
            fromHeight: 1,
            requiredConfirmations: 1,
        ))
        #expect(resumed.tipHeight == result.tipHeight)
        #expect(resumed.anchors == result.anchors)
        #expect(
            resumed.filtersBytes <= result.filtersBytes,
            "a resumed sync must not re-walk the whole filter chain",
        )
    }
}

/// Ad-hoc diagnostic (env-gated): reproduce the phone's exact scan-verify
/// path against the live rig and print the raw verdict.
struct OpenCsvScanDiagTest {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCSV_DIAG_CONSIGNMENT"] != nil))
    func diagnoseScanVerifyVerdict() throws {
        let env = ProcessInfo.processInfo.environment
        let path = env["OPENCSV_DIAG_CONSIGNMENT"]!
        let blob = try Data(contentsOf: URL(fileURLWithPath: path))
        let cacheDir = NSTemporaryDirectory() + "scan-diag-\(UUID().uuidString)"
        let sync = try OpenCsvChainView.scanSync(config: .init(
            network: "regtest",
            peers: ["127.0.0.1:18555"],
            cacheDir: cacheDir,
            fromHeight: 1,
            requiredConfirmations: 6,
        ))
        print("DIAG sync tip \(sync.tipHeight) anchors \(sync.anchors)")
        let wallet = try OpenCsvWallet(secretsJson: OpenCsvWallet.createSecrets())
        do {
            let verdict = try OpenCsvChainView.scanVerify(wallet: wallet, consignment: blob)
            print("DIAG verdict status=\(verdict.status ?? "nil") reason=\(verdict.reason ?? "nil")")
        } catch {
            print("DIAG threw: \(error)")
        }
    }
}
