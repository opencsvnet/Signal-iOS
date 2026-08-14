//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Network
import Testing

@testable import SignalServiceKit

private enum OpenCsvTestContext {
    static let installed: Void = {
        // The Signal app test host installs MainAppContext, whose application
        // group container is unavailable to an unsigned simulator build.
        // InMemoryDB migrations consult that path, so install Signal's
        // purpose-built test context before the first database is created.
        SetCurrentAppContext(TestAppContext(), isRunningTests: true)
    }()
}

private func makeOpenCsvTestDatabase() -> InMemoryDB {
    _ = OpenCsvTestContext.installed
    return InMemoryDB()
}

struct OpenCsvBackgroundWorkPolicyTest {
    @Test
    func confirmingAndDurableWorkRunImmediately() {
        #expect(OpenCsvBackgroundWorkPolicy.urgency(
            activityStates: [.confirming],
            hasPendingDelivery: false,
            hasPendingOperation: false,
            hasInFlightSend: false,
        ) == .immediate)
        #expect(OpenCsvBackgroundWorkPolicy.urgency(
            activityStates: [.awaitingObservers],
            hasPendingDelivery: false,
            hasPendingOperation: false,
            hasInFlightSend: false,
        ) == .immediate)
        #expect(OpenCsvBackgroundWorkPolicy.urgency(
            activityStates: [],
            hasPendingDelivery: true,
            hasPendingOperation: false,
            hasInFlightSend: false,
        ) == .immediate)
        #expect(OpenCsvBackgroundWorkPolicy.urgency(
            activityStates: [],
            hasPendingDelivery: false,
            hasPendingOperation: true,
            hasInFlightSend: false,
        ) == .immediate)
        #expect(OpenCsvBackgroundWorkPolicy.urgency(
            activityStates: [],
            hasPendingDelivery: false,
            hasPendingOperation: false,
            hasInFlightSend: true,
        ) == .immediate)
    }

    @Test
    func unconfirmedSpendableValueIsMonitoredWithoutPollingSettledValue() {
        #expect(OpenCsvBackgroundWorkPolicy.urgency(
            activityStates: [.availableUnconfirmed],
            hasPendingDelivery: false,
            hasPendingOperation: false,
            hasInFlightSend: false,
        ) == .monitor)
        #expect(OpenCsvBackgroundWorkPolicy.urgency(
            activityStates: [.available, .settled, .needsAttention],
            hasPendingDelivery: false,
            hasPendingOperation: false,
            hasInFlightSend: false,
        ) == .never)
    }
}

struct OpenCsvBatchReservePolicyTest {
    private func operation(state: String, feeRate: UInt64?) -> OpenCsvBatchReserveOperation {
        OpenCsvBatchReserveOperation(
            maintenanceId: "maintenance",
            state: state,
            participantCount: 2,
            stockCount: 3,
            feeCellCount: 6,
            signedTxHex: "00",
            txid: String(repeating: "00", count: 32),
            feeRateSatPerVb: feeRate,
        )
    }

    @Test
    func bumpsOnlyLowFeeRelayableMaintenance() {
        #expect(OpenCsvBatchReservePolicy.targetSatPerVb == 4)
        #expect(OpenCsvBatchReservePolicy.shouldFeeBump(operation(
            state: "broadcast_unobserved",
            feeRate: 2,
        )))
        #expect(OpenCsvBatchReservePolicy.shouldFeeBump(operation(
            state: "mempool",
            feeRate: nil,
        )))
        #expect(!OpenCsvBatchReservePolicy.shouldFeeBump(operation(
            state: "mempool",
            feeRate: 4,
        )))
        #expect(!OpenCsvBatchReservePolicy.shouldFeeBump(operation(
            state: "confirmed",
            feeRate: 2,
        )))
        #expect(OpenCsvBatchReservePolicy.shouldFeeBump(
            state: "broadcast_unobserved",
            feeRateSatPerVb: nil,
        ))
    }
}

struct OpenCsvFeeBumpPolicyTest {
    private let txid = String(repeating: "ab", count: 32)

    private func operation(state: String, txid: String?) -> OpenCsvAccountOperationSummary {
        OpenCsvAccountOperationSummary(
            operationId: "operation",
            kind: "transfer",
            state: state,
            txid: txid,
        )
    }

    private func reserve(
        confirmed: UInt64,
        pending: UInt64,
        includesCandidate: Bool = true,
    ) -> OpenCsvAccountStatus.FeeReserve {
        OpenCsvAccountStatus.FeeReserve(
            confirmedSats: confirmed,
            trustedPendingSats: pending,
            untrustedPendingSats: 0,
            immatureSats: 0,
            totalSats: confirmed + pending,
            utxos: includesCandidate ? [
                .init(
                    txid: txid,
                    vout: 2,
                    valueSats: confirmed + pending,
                    keychain: "internal",
                    derivationIndex: 1,
                    reserved: false,
                ),
            ] : [],
        )
    }

    @Test
    func offersRbfOnlyWhileTheCandidateChangeIsPending() {
        let mempool = operation(state: "mempool", txid: txid)
        #expect(OpenCsvFeeBumpPolicy.shouldOffer(
            operation: mempool,
            feeReserve: reserve(confirmed: 0, pending: 8_316),
        ))
        #expect(!OpenCsvFeeBumpPolicy.shouldOffer(
            operation: mempool,
            feeReserve: reserve(confirmed: 8_316, pending: 0),
        ))
        #expect(!OpenCsvFeeBumpPolicy.shouldOffer(
            operation: mempool,
            feeReserve: reserve(confirmed: 0, pending: 8_316, includesCandidate: false),
        ))
        #expect(!OpenCsvFeeBumpPolicy.shouldOffer(
            operation: operation(state: "confirmed", txid: txid),
            feeReserve: reserve(confirmed: 0, pending: 8_316),
        ))
        #expect(!OpenCsvFeeBumpPolicy.shouldOffer(
            operation: operation(state: "mempool", txid: nil),
            feeReserve: reserve(confirmed: 0, pending: 8_316),
        ))
    }
}

struct OpenCsvSyncProvenanceTest {
    @Test
    func parsesStableRustTimestampAndTipStrings() {
        let provenance = OpenCsvAccountStatus.SyncProvenance(
            accelerator: "esplora",
            authoritative: "verified-block",
            verificationPeerCount: 2,
            lastSyncAt: "1785945600",
            lastSyncTip: "316311",
        )
        #expect(provenance.lastSyncDate == Date(timeIntervalSince1970: 1_785_945_600))
        #expect(provenance.lastSyncHeight == 316_311)
    }

    @Test
    func malformedStringsRemainAbsent() {
        let provenance = OpenCsvAccountStatus.SyncProvenance(
            accelerator: "esplora",
            authoritative: "verified-block",
            verificationPeerCount: 2,
            lastSyncAt: "not-a-date",
            lastSyncTip: "not-a-height",
        )
        #expect(provenance.lastSyncDate == nil)
        #expect(provenance.lastSyncHeight == nil)
    }
}

struct OpenCsvPinnedObserverProfileTest {
    @Test
    func builtInSignetProfilesAreImmutableCaChainPins() {
        let mempool = OpenCsvPinnedObserver.mempoolSpace
        #expect(mempool.checkId == "mempool_space_signet")
        #expect(mempool.endpoint == "https://mempool.space/signet/api")
        #expect(mempool.host == "mempool.space")
        #expect(mempool.certificateProfile == "sectigo_r46")
        #expect(mempool.chainPins == [
            "6542d176bed50f193c0ce297ae44ecd8a0a86bec2ede682769344059b4e78530",
            "92f351bf3d54164dfa8dd8f9e1139d3150349786485d2b9eecd00e2971c1e6c5",
        ])

        let blockstream = OpenCsvPinnedObserver.blockstream
        #expect(blockstream.checkId == "blockstream_signet")
        #expect(blockstream.endpoint == "https://blockstream.info/signet/api")
        #expect(blockstream.host == "blockstream.info")
        #expect(blockstream.certificateProfile == "lets_encrypt_yr")
        #expect(blockstream.chainPins.count == 4)
        #expect(blockstream.chainPins.contains(
            "238b85a0099c65b970477d5724f1a1d475ce5058cffe4efa8733899bdb863c47",
        ))

        // Subscriber leaves rotate frequently and are intentionally absent;
        // every reviewed value is an intermediate, root, or cross-certificate.
        #expect(mempool.chainPins.allSatisfy { $0.count == 64 })
        #expect(blockstream.chainPins.allSatisfy { $0.count == 64 })

        // Rust's serde boundary is snake_case even though Swift call sites
        // use native lowerCamelCase case names.
        #expect(OpenCsvObservationKind.rawTransactionApi.rawValue == "raw_transaction_api")
        #expect(OpenCsvObservationKind.directP2pRelay.rawValue == "direct_p2p_relay")
        #expect(OpenCsvObservationKind.experimentalP2pPossession.rawValue == "experimental_p2p_possession")
        #expect(OpenCsvObservationKind.confirmedSpv.rawValue == "confirmed_spv")
        let policy = OpenCsvObservationCheck.defaults(for: "signet")
        #expect(Set(policy[0].chainFingerprintsSha256) == mempool.chainPins)
        #expect(Set(policy[1].chainFingerprintsSha256) == blockstream.chainPins)
    }

    @Test
    func requiredObserverCountTracksEveryRequireMode() {
        let signet = OpenCsvAccountConfig(
            network: "signet",
            esploraUrl: "https://mempool.space/signet/api",
            peers: [],
            verificationPeers: [],
            role: .primary,
            backupVerified: false,
        )
        #expect(signet.requiredRawObserverQuorum == 2)

        let oneRequired = OpenCsvObservationCheck.defaults(for: "signet").map { check in
            OpenCsvObservationCheck(
                id: check.id,
                kind: check.kind,
                endpoint: check.endpoint,
                mode: check.id == "mempool_space_signet" ? .observe : check.mode,
                pinProfile: check.pinProfile,
                chainFingerprintsSha256: check.chainFingerprintsSha256,
                maxAgeSeconds: check.maxAgeSeconds,
            )
        }
        let overridden = OpenCsvAccountConfig(
            network: "signet",
            esploraUrl: "https://mempool.space/signet/api",
            peers: [],
            verificationPeers: [],
            role: .primary,
            backupVerified: false,
            observationChecks: oneRequired,
        )
        #expect(overridden.requiredRawObserverQuorum == 1)

        let regtest = OpenCsvAccountConfig(
            network: "regtest",
            esploraUrl: "http://127.0.0.1:3002",
            peers: [],
            verificationPeers: [],
            role: .primary,
            backupVerified: false,
        )
        #expect(regtest.requiredRawObserverQuorum == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCSV_PINNED_OBSERVER_TXID"] != nil))
    @MainActor
    func livePinnedProvidersReturnTheSameExactTransaction() async throws {
        let txid = try #require(ProcessInfo.processInfo.environment["OPENCSV_PINNED_OBSERVER_TXID"])
        let oldContext = CurrentAppContext()
        await MockSSKEnvironment.activate()
        do {
            let observation = try await OpenCsvPinnedObserver.observeSignetTransaction(
                txid: txid,
                policy: OpenCsvObservationCheck.defaults(for: "signet"),
            )
            #expect(observation.evidence.count == 2)
            #expect(observation.evidence.allSatisfy { $0.result == "observed" })
            #expect(observation.evidence.allSatisfy { !$0.certificateChainFingerprintsSha256.isEmpty })
            #expect(Set(observation.evidence.compactMap(\.rawTransactionHex)).count == 1)
            #expect(observation.rawTransaction.hexadecimalString == observation.evidence[0].rawTransactionHex)
        } catch {
            await MockSSKEnvironment.deactivateAsync(oldContext: oldContext)
            throw error
        }
        await MockSSKEnvironment.deactivateAsync(oldContext: oldContext)
    }
}

struct OpenCsvSecureBackupValidationTest {
    private static let extensionField =
        "in frame 1, item.account has unknown field with tag 17"

    @Test
    func permitsOneStagedForkExtension() {
        #expect(BackupArchiveManagerImpl.unexpectedUnknownBackupFields(
            [Self.extensionField],
            includesOpenCsvWallet: true,
        ).isEmpty)
    }

    @Test
    func neverPermitsExtensionWithoutStagedPayload() {
        #expect(BackupArchiveManagerImpl.unexpectedUnknownBackupFields(
            [Self.extensionField],
            includesOpenCsvWallet: false,
        ) == [Self.extensionField])
    }

    @Test
    func retainsEveryUnrelatedOrMalformedUnknownField() {
        let fields = [
            Self.extensionField,
            "in frame 1, item.account has unknown field with tag 18",
            "in frame nope, item.account has unknown field with tag 17",
            "in frame 2, item.account.iosSpecificSettings has unknown field with tag 17",
        ]
        #expect(BackupArchiveManagerImpl.unexpectedUnknownBackupFields(
            fields,
            includesOpenCsvWallet: true,
        ) == Array(fields.dropFirst()))
    }

    @Test
    func rejectsDuplicateForkExtensions() {
        let fields = [Self.extensionField, Self.extensionField]
        #expect(BackupArchiveManagerImpl.unexpectedUnknownBackupFields(
            fields,
            includesOpenCsvWallet: true,
        ) == fields)
    }
}

struct OpenCsvSendAssetSelectionTest {
    private let openCsvUsd = OpenCsvCredit(
        assetId: String(repeating: "11", count: 32),
        currency: "USD",
        amount: 40,
    )
    private let tetherUsd = OpenCsvCredit(
        assetId: String(repeating: "22", count: 32),
        currency: "USD",
        amount: 100,
    )

    private func instrument(
        assetId: String,
        issuer: String,
        priority: UInt32,
        profile: String = "trusted_test_usd_v2",
        trustState: String = "trusted_configuration",
    ) -> OpenCsvInstrumentRecord {
        OpenCsvInstrumentRecord(
            assetId: assetId,
            trustState: trustState,
            profile: profile,
            issuerPriority: priority,
            manifest: OpenCsvInstrumentManifest(
                terms: OpenCsvInstrumentTerms(
                    network: "signet",
                    displayName: "\(issuer) USD",
                    unitCode: "USD",
                    decimals: 6,
                    issuerName: issuer,
                    termsUri: "https://example.com/terms",
                    redemptionSummary: "test",
                    testOnly: true,
                ),
                genesis: .init(
                    issuerPk: Array(repeating: 1, count: 32),
                    currencyCode: Array("USD".utf8),
                    termsHash: Array(repeating: 2, count: 32),
                    nonce: UInt64(priority),
                ),
            ),
        )
    }

    @Test
    func priorityChoosesFirstIssuerThatCoversTheWholeSend() throws {
        let instruments = [
            instrument(assetId: openCsvUsd.assetId, issuer: "OpenCSV", priority: 0),
            instrument(assetId: tetherUsd.assetId, issuer: "Tether", priority: 10),
        ]
        #expect(try OpenCsvPayments.resolveUsdSendAsset(
            [tetherUsd, openCsvUsd],
            instruments: instruments,
            amount: 30,
            requestedAssetId: nil,
        ).credit == openCsvUsd)
        #expect(try OpenCsvPayments.resolveUsdSendAsset(
            [openCsvUsd, tetherUsd],
            instruments: instruments,
            amount: 50,
            requestedAssetId: nil,
        ).credit == tetherUsd)
    }

    @Test
    func exactReviewedIssuerChoiceNeverFallsThrough() throws {
        let instruments = [
            instrument(assetId: openCsvUsd.assetId, issuer: "OpenCSV", priority: 0),
            instrument(assetId: tetherUsd.assetId, issuer: "Tether", priority: 10),
        ]
        #expect(try OpenCsvPayments.resolveUsdSendAsset(
            [openCsvUsd, tetherUsd],
            instruments: instruments,
            amount: 20,
            requestedAssetId: tetherUsd.assetId,
        ).credit == tetherUsd)
    }

    @Test
    func neverSilentlyCombinesIssuerClaims() {
        let smallerTether = OpenCsvCredit(
            assetId: tetherUsd.assetId,
            currency: "USD",
            amount: 25,
        )
        do {
            _ = try OpenCsvPayments.resolveUsdSendAsset(
                [openCsvUsd, smallerTether],
                instruments: [
                    instrument(assetId: openCsvUsd.assetId, issuer: "OpenCSV", priority: 0),
                    instrument(assetId: tetherUsd.assetId, issuer: "Tether", priority: 10),
                ],
                amount: 60,
                requestedAssetId: nil,
            )
            Issue.record("expected an issuer split rejection")
        } catch OpenCsvPaymentsError.issuerSplitRequired(let totalAvailable) {
            #expect(totalAvailable == 65)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func untrustedTickerLookalikeAndStaleChoiceAreExcluded() {
        let untrusted = instrument(
            assetId: openCsvUsd.assetId,
            issuer: "Impostor",
            priority: 0,
            profile: "untrusted_manifest",
            trustState: "untrusted",
        )
        do {
            _ = try OpenCsvPayments.resolveUsdSendAsset(
                [openCsvUsd],
                instruments: [untrusted],
                amount: 1,
                requestedAssetId: String(repeating: "33", count: 32),
            )
            Issue.record("expected zero trusted funds")
        } catch OpenCsvPaymentsError.insufficientFunds(let available) {
            #expect(available == 0)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

struct OpenCsvUsdAmountTest {
    @Test
    func parsesHumanAmountsExactly() {
        #expect(OpenCsvUsdAmount.parse("1") == 1_000_000)
        #expect(OpenCsvUsdAmount.parse("1.25") == 1_250_000)
        #expect(OpenCsvUsdAmount.parse("0.000001") == 1)
        #expect(OpenCsvUsdAmount.parse(" 42.5 ") == 42_500_000)
    }

    @Test
    func rejectsAmbiguousInvalidOrOverflowingAmounts() {
        for invalid in ["", ".5", "1.", "-1", "1.0000001", "1,25", "USD 1"] {
            #expect(OpenCsvUsdAmount.parse(invalid) == nil)
        }
        #expect(OpenCsvUsdAmount.parse("18446744073709551615") == nil)
    }

    @Test
    func formatsWithoutInventingPrecision() {
        #expect(OpenCsvUsdAmount.format(0) == "0")
        #expect(OpenCsvUsdAmount.format(1) == "0.000001")
        #expect(OpenCsvUsdAmount.format(1_250_000) == "1.25")
    }
}

struct OpenCsvFeeReservePolicyTest {
    private func reserve(
        confirmedSats: UInt64,
        outputs: [(value: UInt64, reserved: Bool)],
    ) -> OpenCsvAccountStatus.FeeReserve {
        OpenCsvAccountStatus.FeeReserve(
            confirmedSats: confirmedSats,
            trustedPendingSats: 0,
            untrustedPendingSats: 0,
            immatureSats: 0,
            totalSats: confirmedSats,
            utxos: outputs.enumerated().map { index, output in
                OpenCsvAccountStatus.FeeReserve.Utxo(
                    txid: String(repeating: "ab", count: 32),
                    vout: UInt32(index),
                    valueSats: output.value,
                    keychain: "external",
                    derivationIndex: UInt32(index),
                    reserved: output.reserved,
                )
            },
        )
    }

    @Test
    func requiresOneConfirmedUnreservedOutputAtThePinnedMinimum() {
        #expect(OpenCsvPayments.minimumFeeReserveSats == 2_500)
        #expect(!OpenCsvPayments.hasConfirmedUnreservedFeeUtxo(reserve(
            confirmedSats: 2_499,
            outputs: [(2_499, false)],
        )))
        #expect(!OpenCsvPayments.hasConfirmedUnreservedFeeUtxo(reserve(
            confirmedSats: 2_500,
            outputs: [(2_500, true)],
        )))
        #expect(!OpenCsvPayments.hasConfirmedUnreservedFeeUtxo(reserve(
            confirmedSats: 2_500,
            outputs: [(1_250, false), (1_250, false)],
        )))
        #expect(OpenCsvPayments.hasConfirmedUnreservedFeeUtxo(reserve(
            confirmedSats: 2_500,
            outputs: [(2_500, false)],
        )))
    }
}

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
        #expect(OpenCsvAttachmentDetector.isConsignment(
            sourceFilename: "test-usd-v2-carol-50-50.opencsv",
            mimeType: "application/octet-stream",
            bodyText: nil,
        ))
        #expect(OpenCsvAttachmentDetector.isConsignment(
            sourceFilename: "PAYMENT.OPENCsv",
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
        {"status":"verified","consignment_id":"canonical-1",
         "credits":[{"asset_id":"ab12","currency":"USD","amount":100}],
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
        #expect(verdict.consignmentId == "canonical-1")

        let record = OpenCsvVerdictRecord(verdict: verdict, date: Date(timeIntervalSince1970: 0))
        #expect(record.isVerified)
        #expect(record.amount == 100)
        #expect(record.currency == "USD")
    }

    @Test
    func decodesRejectedVerdict() throws {
        let json = #"{"status":"rejected","consignment_id":"canonical-2","reason":"InsufficientConfirmations { have: 1, required: 6 }"}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let verdict = try decoder.decode(OpenCsvVerdict.self, from: Data(json.utf8))
        #expect(!verdict.isVerified)
        let record = OpenCsvVerdictRecord(verdict: verdict, date: Date(timeIntervalSince1970: 0))
        #expect(!record.isVerified)
        #expect(record.amount == 0)
        #expect(record.reason?.contains("InsufficientConfirmations") == true)
        #expect(verdict.consignmentId == "canonical-2")
    }
}

@Suite(.serialized)
final class OpenCsvWalletStoreTest {
    // Swift Testing may construct suite instances concurrently before a
    // serialized suite starts running. Defer Signal's process-global test DB
    // setup until the individual test has entered the serialized executor.
    private lazy var db = makeOpenCsvTestDatabase()
    private lazy var store = OpenCsvWalletStore(keychainStorage: MockKeychainStorage())

    @Test
    func verifiedChainViewSurvivesRelaunchAndDrivesCachedPresentation() throws {
        let receipt = OpenCsvVerifiedChainView(
            tipHeight: 316_311,
            observedAt: Date(timeIntervalSince1970: 1_785_945_600),
        )
        try db.write { tx in try store.setVerifiedChainView(receipt, tx: tx) }
        db.read { tx in #expect(store.verifiedChainView(tx: tx) == receipt) }
    }

    @Test
    func walletPresentationSnapshotBytesSurviveRelaunch() throws {
        let snapshot = Data(#"{"cached_at":1786579200,"balance":135}"#.utf8)
        db.write { tx in store.setWalletPresentationSnapshotData(snapshot, tx: tx) }
        db.read { tx in
            #expect(store.walletPresentationSnapshotData(tx: tx) == snapshot)
        }
    }

    @Test
    func linkedProvisioningCarriesOnlyValidatedPublicMaterial() throws {
        let watch = OpenCsvLinkedWatchAccount(
            externalDescriptor: "wpkh([fingerprint/84h/1h/0h]xpub-external/0/*)",
            internalDescriptor: "wpkh([fingerprint/84h/1h/0h]xpub-internal/1/*)",
            owner: String(repeating: "ab", count: 32),
        )
        #expect(watch.isValidForLinkedProvisioning)
        let encoded = try JSONEncoder().encode(watch)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        #expect(!encodedText.contains("root"))
        #expect(!encodedText.contains("secret"))
        try db.write { tx in try store.setLinkedWatchAccount(watch, tx: tx) }
        db.read { tx in
            let storedWatch = try! store.linkedWatchAccount(tx: tx)
            #expect(storedWatch == watch)
        }

        let secretShaped = OpenCsvLinkedWatchAccount(
            externalDescriptor: "wpkh([fingerprint/84h/1h/0h]tprv-private/0/*)",
            internalDescriptor: "wpkh([fingerprint/84h/1h/0h]tprv-private/1/*)",
            owner: String(repeating: "cd", count: 32),
        )
        #expect(!secretShaped.isValidForLinkedProvisioning)
    }

    @Test
    func secretsRoundTripThroughKeychain() throws {
        #expect(try store.walletSecrets() == nil)
        try store.setWalletSecrets(#"{"version":1}"#)
        #expect(try store.walletSecrets() == #"{"version":1}"#)
    }

    @Test
    func freshAccountMaterialCreatesRootAndBindingTogether() throws {
        let keychain = MockKeychainStorage()
        let store = OpenCsvWalletStore(keychainStorage: keychain)
        var generatedByte: UInt8 = 0
        let material = try store.createPrimaryAccountMaterial { count in
            generatedByte += 1
            return Data(repeating: generatedByte, count: count)
        }

        #expect(material.accountRoot == Data(repeating: 1, count: 32))
        #expect(material.deviceBinding == Data(repeating: 2, count: 32))
        #expect(!material.isRestoredReadOnly)
        #expect(try store.accountMaterial() == material)

        let reopened = try store.createPrimaryAccountMaterial { count in
            Data(repeating: 9, count: count)
        }
        #expect(reopened == material)
    }

    @Test
    func restoredRootNeverManufacturesAReplacementBinding() throws {
        let store = OpenCsvWalletStore(keychainStorage: MockKeychainStorage())
        let root = Data(repeating: 3, count: 32)
        try store.installRestoredAccountRoot(root)
        var generatorWasCalled = false

        let material = try store.createPrimaryAccountMaterial { count in
            generatorWasCalled = true
            return Data(repeating: 4, count: count)
        }

        #expect(!generatorWasCalled)
        #expect(material.accountRoot == root)
        #expect(material.deviceBinding == nil)
        #expect(material.isRestoredReadOnly)
    }

    @Test
    func restoredRootCannotReplaceExistingAccount() throws {
        let store = OpenCsvWalletStore(keychainStorage: MockKeychainStorage())
        _ = try store.createPrimaryAccountMaterial { count in
            Data(repeating: 5, count: count)
        }

        #expect(throws: OpenCsvAccountMaterialError.conflictingAccountRoot) {
            try store.installRestoredAccountRoot(Data(repeating: 6, count: 32))
        }
    }

#if DEBUG && OPENCSV_TEST_WALLET_RECOVERY
    @Test
    func testDeviceRebindMaterialIsStableAndCrashResumable() throws {
        let keychain = MockKeychainStorage()
        let store = OpenCsvWalletStore(keychainStorage: keychain)
        let root = Data(repeating: 7, count: 32)
        try store.installRestoredAccountRoot(root)
        let payload = try OpenCsvSecureBackupPayload(
            version: 4,
            accountRoot: root,
            checkpointJson: #"{"checkpoint":{"version":4,"deployment_id":"opencsv-test-usd-v2"}}"#,
            checkpointHash: String(repeating: "a", count: 64),
            deviceBindingCommitment: String(repeating: "b", count: 64),
        )
        let first = try store.beginTestDeviceRebind(payload: payload) { count in
            Data(repeating: 8, count: count)
        }
        let replay = try store.beginTestDeviceRebind(payload: payload) { count in
            Data(repeating: 9, count: count)
        }
        #expect(first == replay)
        #expect(first.newDeviceBinding == Data(repeating: 8, count: 32))
        #expect(first.newDeviceBindingCommitment.count == 64)

        var advanced = first
        advanced.stage = .checkpointReady
        advanced.checkpointHash = String(repeating: "c", count: 64)
        try store.setPendingTestDeviceRebind(advanced)
        #expect(try store.pendingTestDeviceRebind() == advanced)

        try store.installReboundAccountMaterial(root: root, binding: advanced.newDeviceBinding)
        let rebound = try #require(try store.accountMaterial())
        #expect(rebound.accountRoot == root)
        #expect(rebound.deviceBinding == advanced.newDeviceBinding)
        try store.finishTestDeviceRebind()
        #expect(try store.pendingTestDeviceRebind() == nil)
    }
#endif

    @Test
    func secureBackupPayloadCarriesRootButNoDeviceBinding() throws {
        let root = Data(repeating: 7, count: 32)
        let payload = try OpenCsvSecureBackupPayload(
            version: 4,
            accountRoot: root,
            checkpointJson: #"{"checkpoint":{"version":4,"deployment_id":"opencsv-test-usd-v2"}}"#,
            checkpointHash: "checkpoint-hash",
            deviceBindingCommitment: "public-binding-commitment",
        )
        try db.write { tx in
            try store.setSecureBackupPayload(payload, tx: tx)
        }
        let restored = try db.read { tx in
            try store.secureBackupPayload(tx: tx)
        }
        #expect(restored == payload)
        #expect(restored?.accountRoot == root)
    }

    @Test
    func v1SecureBackupCannotBeReinterpretedAsV2() {
        #expect(throws: OpenCsvAccountMaterialError.invalidLength) {
            _ = try OpenCsvSecureBackupPayload(
                version: 1,
                accountRoot: Data(repeating: 7, count: 32),
                checkpointJson: #"{"checkpoint":{"version":1}}"#,
                checkpointHash: "archived-v1",
                deviceBindingCommitment: "archived-v1",
            )
        }
    }

    @Test
    func observationModesPersistWithoutChangingReviewedEndpointsOrPins() throws {
        let original = db.read { store.observationChecks(tx: $0) }
        let mempool = try #require(original.first { $0.id == "mempool_space_signet" })
        #expect(mempool.mode == .require)
        #expect(mempool.endpoint == "https://mempool.space/signet/api")
        #expect(mempool.pinProfile == "sectigo_r46")

        var changedKnownCheck = false
        var changedUnknownCheck = true
        try db.write { tx in
            changedKnownCheck = try store.setObservationMode(.observe, checkId: mempool.id, tx: tx)
            changedUnknownCheck = try store.setObservationMode(.off, checkId: "typo.example", tx: tx)
        }
        #expect(changedKnownCheck)
        #expect(!changedUnknownCheck)

        let reopened = db.read { store.observationChecks(tx: $0) }
        let changed = try #require(reopened.first { $0.id == mempool.id })
        #expect(changed.mode == .observe)
        #expect(changed.endpoint == mempool.endpoint)
        #expect(changed.pinProfile == mempool.pinProfile)
        #expect(changed.kind == mempool.kind)
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

    @Test
    func incomingActivitySeparatesVerifyingUnconfirmedAndSettled() throws {
        let firstSeen = Date(timeIntervalSince1970: 10)
        try db.write { tx in
            try store.upsertIncomingActivity(
                attachmentId: 42,
                threadUniqueId: "thread-1",
                messageUniqueId: "message-1",
                state: .confirming,
                detail: "awaiting verified chain settlement",
                now: firstSeen,
                tx: tx,
            )
        }
        db.read { tx in
            let activity = store.incomingActivities(tx: tx).first
            #expect(activity?.state == .confirming)
            #expect(activity?.amount == nil)
            #expect(store.verdict(attachmentId: 42, tx: tx) == nil)
            #expect(store.replayBlobs(tx: tx).isEmpty)
        }

        try db.write { tx in
            try store.upsertIncomingActivity(
                attachmentId: 42,
                threadUniqueId: nil,
                messageUniqueId: nil,
                state: .availableUnconfirmed,
                amount: 25_000_000,
                currency: "USD",
                now: Date(timeIntervalSince1970: 20),
                tx: tx,
            )
        }
        db.read { tx in
            let activity = store.incomingActivities(tx: tx).first
            #expect(activity?.state == .availableUnconfirmed)
            #expect(activity?.state.isSpendable == true)
            #expect(activity?.state.isSettled == false)
            #expect(activity?.amount == 25_000_000)
            #expect(activity?.threadUniqueId == "thread-1")
            #expect(activity?.messageUniqueId == "message-1")
            #expect(activity?.firstSeenAt == firstSeen)
        }

        // A temporary loss of required observer agreement freezes spending
        // but retains the already verified amount for honest presentation.
        try db.write { tx in
            try store.upsertIncomingActivity(
                attachmentId: 42,
                threadUniqueId: nil,
                messageUniqueId: nil,
                state: .awaitingObservers,
                detail: "waiting for required network verification",
                now: Date(timeIntervalSince1970: 25),
                tx: tx,
            )
        }
        db.read { tx in
            let activity = store.incomingActivities(tx: tx).first
            #expect(activity?.state == .awaitingObservers)
            #expect(activity?.state.isSpendable == false)
            #expect(activity?.state.isSettled == false)
            #expect(activity?.amount == 25_000_000)
            #expect(activity?.currency == "USD")
        }

        // Confirmation promotes the same spendable value to settled.
        try db.write { tx in
            try store.upsertIncomingActivity(
                attachmentId: 42,
                threadUniqueId: nil,
                messageUniqueId: nil,
                state: .settled,
                amount: 25_000_000,
                currency: "USD",
                now: Date(timeIntervalSince1970: 30),
                tx: tx,
            )
        }
        db.read { tx in
            let activity = store.incomingActivities(tx: tx).first
            #expect(activity?.state == .settled)
            #expect(activity?.state.isSettled == true)
            #expect(activity?.amount == 25_000_000)
            #expect(store.verdict(attachmentId: 42, tx: tx) == nil)
            #expect(store.replayBlobs(tx: tx).isEmpty)
        }

        try db.write { tx in
            try store.upsertIncomingActivity(
                attachmentId: 42,
                threadUniqueId: nil,
                messageUniqueId: nil,
                state: .needsAttention,
                amount: 25_000_000,
                detail: "rejected",
                now: Date(timeIntervalSince1970: 40),
                tx: tx,
            )
        }
        db.read { tx in
            let activity = store.incomingActivities(tx: tx).first
            #expect(activity?.state == .needsAttention)
            #expect(activity?.amount == nil)
        }
    }

    @Test
    func canonicalConsignmentIdentityDeduplicatesTransportEncodings() throws {
        let canonicalId = String(repeating: "cd", count: 32)
        let record = OpenCsvVerdictRecord(
            verdict: OpenCsvVerdict(
                status: "verified",
                reason: nil,
                credits: [OpenCsvCredit(assetId: "ab", currency: "USD", amount: 7)],
                coins: nil,
                anchor: nil,
                consignmentId: canonicalId,
            ),
            date: Date(timeIntervalSince1970: 0),
        )
        db.write { tx in
            store.setVerdict(
                record,
                blob: Data([1]),
                attachmentId: 42,
                messageUniqueId: "message-first",
                tx: tx,
            )
            store.setVerdict(
                record,
                blob: Data([2]),
                attachmentId: 43,
                messageUniqueId: "message-retry",
                tx: tx,
            )
        }
        db.read { tx in
            #expect(store.verdict(attachmentId: 42, tx: tx) == record)
            #expect(store.verdict(attachmentId: 43, tx: tx) == record)
            #expect(store.replayBlobs(tx: tx).map(\.entry) == ["c:\(canonicalId)"])
            #expect(store.blobForAttachment(attachmentId: 42, tx: tx) == Data([2]))
            #expect(store.blobForAttachment(attachmentId: 43, tx: tx) == Data([2]))
            #expect(store.isCanonicalPresentationAttachment(
                attachmentId: 42,
                messageUniqueId: "message-first",
                tx: tx,
            ))
            #expect(!store.isCanonicalPresentationAttachment(
                attachmentId: 43,
                messageUniqueId: "message-retry",
                tx: tx,
            ))
            // Signal may deduplicate two byte-identical transports to one
            // attachment row. Message identity still admits only the first.
            #expect(!store.isCanonicalPresentationAttachment(
                attachmentId: 42,
                messageUniqueId: "message-retry",
                tx: tx,
            ))
            #expect(store.hasCanonicalPresentation(consignmentId: canonicalId, tx: tx))
            #expect(!store.hasCanonicalPresentation(consignmentId: "not-present", tx: tx))
        }
    }

    @Test
    func canonicalPresentationLookupUsesStablePaymentIdentity() throws {
        let consignmentId = String(repeating: "ca", count: 32)
        let paymentId = String(repeating: "03", count: 32)
        let record = OpenCsvVerdictRecord(
            sentAmount: 10_000_000,
            currency: "USD",
            assetId: "test-usd",
            consignmentId: consignmentId,
            paymentId: paymentId,
            date: Date(timeIntervalSince1970: 0),
        )

        db.write { tx in
            store.setVerdict(
                record,
                blob: nil,
                attachmentId: 44,
                messageUniqueId: "message-first",
                tx: tx,
            )
        }

        db.read { tx in
            #expect(store.hasCanonicalPresentation(consignmentId: consignmentId, tx: tx))
            #expect(!store.hasCanonicalPresentation(
                consignmentId: String(repeating: "00", count: 32),
                tx: tx,
            ))
        }
    }

    @Test
    func verifiedRbfReplacementSupersedesTheOldPaymentPresentation() throws {
        let originalId = String(repeating: "01", count: 32)
        let replacementId = String(repeating: "02", count: 32)
        let paymentId = String(repeating: "03", count: 32)
        let original = OpenCsvVerdictRecord(
            verdict: OpenCsvVerdict(
                status: "verified",
                reason: nil,
                credits: [OpenCsvCredit(assetId: "ab", currency: "USD", amount: 1)],
                coins: nil,
                anchor: nil,
                consignmentId: originalId,
                finality: "unconfirmed",
                spendable: true,
            ),
            date: Date(timeIntervalSince1970: 0),
        )
        let replacement = OpenCsvVerdictRecord(
            verdict: OpenCsvVerdict(
                status: "verified",
                reason: nil,
                credits: [OpenCsvCredit(assetId: "ab", currency: "USD", amount: 1)],
                coins: nil,
                anchor: nil,
                consignmentId: replacementId,
                paymentId: paymentId,
                supersededConsignmentIds: [originalId],
                finality: "unconfirmed",
                spendable: true,
            ),
            date: Date(timeIntervalSince1970: 1),
        )
        try db.write { tx in
            store.setVerdict(
                original,
                blob: Data([1]),
                attachmentId: 50,
                messageUniqueId: "message-original",
                tx: tx,
            )
            try store.upsertIncomingActivity(
                attachmentId: 50,
                threadUniqueId: "thread",
                messageUniqueId: "message-original",
                state: .availableUnconfirmed,
                amount: 1,
                currency: "USD",
                tx: tx,
            )
            store.setVerdict(
                replacement,
                blob: Data([2]),
                attachmentId: 51,
                messageUniqueId: "message-replacement",
                tx: tx,
            )
        }
        db.read { tx in
            #expect(!store.isCanonicalPresentationAttachment(
                attachmentId: 50,
                messageUniqueId: "message-original",
                tx: tx,
            ))
            #expect(store.isCanonicalPresentationAttachment(
                attachmentId: 51,
                messageUniqueId: "message-replacement",
                tx: tx,
            ))
            #expect(store.incomingActivities(tx: tx).isEmpty)
            let superseded = store.verdict(attachmentId: 50, tx: tx)
            #expect(superseded?.status == "rejected")
            #expect(superseded?.reason == "superseded_consignment")
            #expect(superseded?.finality == "superseded")
            #expect(superseded?.spendable == false)
            #expect(!OpenCsvPayments.shouldRetryStoredVerdict(superseded))
            #expect(store.replayBlobs(tx: tx).map(\.entry) == ["c:\(replacementId)"])
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
        #expect(sent.formattedAmount == "0.000005")

        let oneDollar = OpenCsvVerdictRecord(
            sentAmount: 1_000_000,
            currency: "USD",
            assetId: "ab",
            date: Date(timeIntervalSince1970: 0),
        )
        #expect(oneDollar.formattedAmount == "1")

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
            operationKind: "mint",
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

    @Test
    func accountDeliveryCommitIsCrashRecoverableAndNotReenqueued() throws {
        let operation = OpenCsvWalletStore.PendingAccountOperation(
            operationId: "operation-1",
            threadUniqueId: "thread-1",
            amount: 5,
            currency: "USD",
            assetId: "ab",
            kind: "mint",
            createdAt: Date(timeIntervalSince1970: 0),
        )
        let delivery = OpenCsvWalletStore.PendingDelivery(
            threadUniqueId: "thread-1",
            body: "OpenCSV consignment",
            replayEntry: "o:1",
            amount: 5,
            currency: "USD",
            assetId: "ab",
            operationKind: operation.kind,
            operationId: operation.operationId,
            deliveryNonce: "nonce-1",
            consignmentId: "consignment-1",
            createdAt: operation.createdAt,
        )
        try db.write { tx in
            try store.upsertPendingAccountOperation(operation, tx: tx)
            try store.addPendingDelivery(delivery, tx: tx)
            try store.markPendingDeliveryEnqueued(id: delivery.id, tx: tx)
        }
        db.read { tx in
            let stored = store.pendingDeliveries(tx: tx).first
            let pendingOperations = try! store.pendingAccountOperations(tx: tx)
            #expect(stored?.enqueuedAt != nil)
            #expect(stored?.operationKind == "mint")
            #expect(pendingOperations == [operation])
        }
        try db.write { tx in
            try store.removePendingDelivery(id: delivery.id, tx: tx)
            try store.removePendingAccountOperation(operationId: operation.operationId, tx: tx)
        }
        db.read { tx in
            let pendingOperations = try! store.pendingAccountOperations(tx: tx)
            #expect(store.pendingDeliveries(tx: tx).isEmpty)
            #expect(pendingOperations.isEmpty)
        }
    }

    @Test
    func accountDeliveryIsIdempotentByExactConsignmentAndKeepsRbfReplacement() throws {
        let first = OpenCsvWalletStore.PendingDelivery(
            id: "delivery-first",
            threadUniqueId: "thread-1",
            body: "OpenCSV consignment",
            replayEntry: "o:1",
            amount: 25,
            currency: "USD",
            assetId: "ab",
            operationKind: "transfer",
            operationId: "operation-1",
            deliveryNonce: "nonce-1",
            consignmentId: "consignment-1",
            createdAt: Date(timeIntervalSince1970: 0),
        )
        let reconstructed = OpenCsvWalletStore.PendingDelivery(
            id: "delivery-after-relaunch",
            threadUniqueId: "thread-1",
            body: "OpenCSV consignment",
            replayEntry: "o:2",
            amount: 25,
            currency: "USD",
            assetId: "ab",
            operationKind: "transfer",
            operationId: "operation-1",
            deliveryNonce: "nonce-1",
            consignmentId: "consignment-1",
            createdAt: Date(timeIntervalSince1970: 1),
        )
        let replacement = OpenCsvWalletStore.PendingDelivery(
            id: "delivery-replacement",
            threadUniqueId: "thread-1",
            body: "OpenCSV replacement consignment",
            replayEntry: "o:3",
            amount: 25,
            currency: "USD",
            assetId: "ab",
            operationKind: "transfer",
            operationId: "operation-1",
            deliveryNonce: "nonce-2",
            consignmentId: "consignment-2",
            replacesTxid: "original-txid",
            createdAt: Date(timeIntervalSince1970: 2),
        )
        try db.write { tx in
            try store.addPendingDelivery(first, tx: tx)
            try store.addPendingDelivery(reconstructed, tx: tx)
            try store.addPendingDelivery(replacement, tx: tx)
        }
        db.read { tx in
            #expect(store.pendingDeliveries(tx: tx) == [first, replacement])
            let deliveries = store.pendingDeliveries(tx: tx)
            #expect(OpenCsvPayments.pendingDelivery(
                operationId: "operation-1",
                consignmentId: "consignment-1",
                in: deliveries,
            ) == first)
            #expect(OpenCsvPayments.pendingDelivery(
                operationId: "operation-1",
                consignmentId: "consignment-2",
                in: deliveries,
            ) == replacement)
            #expect(OpenCsvPayments.pendingDelivery(
                operationId: "operation-1",
                consignmentId: "consignment-3",
                in: deliveries,
            ) == nil)
        }
    }

    @Test
    func plannedTransferMetadataSurvivesBeforeProofAndSchedulesImmediateWork() throws {
        let operation = OpenCsvWalletStore.PendingAccountOperation(
            operationId: "planned-transfer-1",
            threadUniqueId: "thread-1",
            amount: 1_000_000,
            currency: "USD",
            assetId: String(repeating: "ab", count: 32),
            kind: "transfer",
            createdAt: Date(timeIntervalSince1970: 1),
            batchLocalId: "batch-1",
            batchDeadlineMs: 1_785_945_602_000,
            batchOrdinal: 0,
        )
        try db.write { tx in
            try store.upsertPendingAccountOperation(operation, tx: tx)
        }
        db.read { tx in
            #expect((try? store.pendingAccountOperations(tx: tx)) == [operation])
            #expect((try? store.pendingAccountOperations(tx: tx).first?.batchLocalId) == "batch-1")
            #expect(store.backgroundWorkUrgency(tx: tx) == .immediate)
            #expect(store.pendingDeliveries(tx: tx).isEmpty)
        }
        try db.write { tx in
            try store.markPendingAccountOperationAnnounced(
                operationId: operation.operationId,
                messageId: "message-1",
                tx: tx,
            )
        }
        db.read { tx in
            let stored = (try? store.pendingAccountOperations(tx: tx))?.first
            #expect(stored?.announcementMessageId == "message-1")
            #expect(stored?.announcementEnqueuedAt != nil)
            #expect(store.backgroundWorkUrgency(tx: tx) == .immediate)
        }
        try db.write { tx in
            try store.markPendingAccountOperationFailed(
                operationId: operation.operationId,
                reason: "insufficient_fees",
                tx: tx,
            )
        }
        db.read { tx in
            let stored = (try? store.pendingAccountOperations(tx: tx))?.first
            #expect(stored?.failureReason == "insufficient_fees")
            #expect(store.backgroundWorkUrgency(tx: tx) == .immediate)
        }
    }

    @Test
    func legacyPendingOperationDecodesWithoutBatchMetadata() throws {
        let legacy = #"{"operationId":"legacy-1","threadUniqueId":"thread-1","amount":1,"currency":"USD","assetId":"ab","kind":"transfer","createdAt":0}"#
        let decoded = try JSONDecoder().decode(
            OpenCsvWalletStore.PendingAccountOperation.self,
            from: Data(legacy.utf8),
        )
        #expect(decoded.operationId == "legacy-1")
        #expect(decoded.batchLocalId == nil)
        #expect(decoded.batchDeadlineMs == nil)
        #expect(decoded.batchOrdinal == nil)
    }

    @Test
    func removingCancelledBatchMetadataLeavesIndependentQueueEntries() throws {
        let makeOperation = { (id: String, batch: String?) in
            OpenCsvWalletStore.PendingAccountOperation(
                operationId: id,
                threadUniqueId: "thread-\(id)",
                amount: 1,
                currency: "USD",
                assetId: "ab",
                kind: "transfer",
                createdAt: Date(timeIntervalSince1970: 0),
                batchLocalId: batch,
                batchDeadlineMs: batch == nil ? nil : 2_000,
                batchOrdinal: batch == nil ? nil : 0,
            )
        }
        try db.write { tx in
            try store.upsertPendingAccountOperation(makeOperation("a", "batch-1"), tx: tx)
            try store.upsertPendingAccountOperation(makeOperation("b", "batch-1"), tx: tx)
            try store.upsertPendingAccountOperation(makeOperation("c", "batch-2"), tx: tx)
            try store.upsertPendingAccountOperation(makeOperation("legacy", nil), tx: tx)
            try store.removePendingAccountOperations(batchLocalId: "batch-1", tx: tx)
        }
        let remaining = try db.read { try store.pendingAccountOperations(tx: $0) }
        #expect(remaining.map(\.operationId) == ["c", "legacy"])
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
            threadUniqueId: "t",
            body: "a",
            replayEntry: "o:1",
            amount: 1,
            currency: nil,
            assetId: nil,
            createdAt: Date(timeIntervalSince1970: 0),
        )
        let b = OpenCsvWalletStore.PendingDelivery(
            threadUniqueId: "t",
            body: "b",
            replayEntry: "o:2",
            amount: 2,
            currency: nil,
            assetId: nil,
            createdAt: Date(timeIntervalSince1970: 1),
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
            #expect(store.scanFromHeight(tx: tx) == 316_000)
        }
        try db.write { tx in try store.setSpvPeers(["node.example:38333"], tx: tx) }
        db.read { tx in #expect(store.spvPeers(tx: tx) == ["node.example:38333"]) }

        db.write { tx in store.setNetwork("mainnet", tx: tx) }
        db.read { tx in #expect(store.scanFromHeight(tx: tx) == 1) }

        try db.write { tx in try store.setScanFromHeight(42, tx: tx) }
        db.read { tx in #expect(store.scanFromHeight(tx: tx) == 42) }
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

struct OpenCsvReviewedUsdIssuersTest {
    @Test
    func signetPinsTheExactBackedUpV2Manifest() throws {
        let policies = OpenCsvReviewedUsdIssuers.policies(for: "signet")
        #expect(policies.count == 1)
        let policy = try #require(policies.first)
        #expect(OpenCsvReviewedUsdIssuers.signetTestUsdAssetId == "8a88b56e42450f5761b521063df3fa16806add5c434584441d3b626556115d62")
        #expect(policy.priority == 0)
        #expect(policy.manifest.terms.network == "signet")
        #expect(policy.manifest.terms.unitCode == "USD")
        #expect(policy.manifest.terms.decimals == 6)
        #expect(policy.manifest.terms.testOnly)
        #expect(policy.manifest.terms.displayName == "OpenCSV Test USD v2")
        #expect(policy.manifest.terms.termsUri == "https://opencsv.net/usd-preview/terms-v2")
        #expect(policy.manifest.genesis.currencyCode == Array("USD".utf8))
        #expect(policy.manifest.genesis.issuerPk.count == 32)
        #expect(policy.manifest.genesis.termsHash.count == 32)
    }

    @Test
    func productionNetworksDoNotTrustThePreviewIssuer() {
        #expect(OpenCsvReviewedUsdIssuers.policies(for: "mainnet").isEmpty)
        #expect(OpenCsvReviewedUsdIssuers.policies(for: "regtest").isEmpty)
    }

    @Test
    func accountConfigDefaultsToTheCleanV2Deployment() {
        let signet = OpenCsvAccountConfig(
            network: "signet",
            esploraUrl: "https://mempool.space/signet/api",
            peers: [],
            verificationPeers: [],
            role: .primary,
            backupVerified: false,
        )
        #expect(signet.version == 2)
        #expect(signet.deploymentId == "opencsv-test-usd-v2")

        let mainnet = OpenCsvAccountConfig(
            network: "mainnet",
            esploraUrl: "https://mempool.space/api",
            peers: [],
            verificationPeers: [],
            role: .primary,
            backupVerified: false,
        )
        #expect(mainnet.deploymentId == "opencsv-mainnet")
    }

    @Test
    func testUsdPresentationRequiresExactReviewedSignetIdentity() throws {
        let assetId = OpenCsvReviewedUsdIssuers.signetTestUsdAssetId
        #expect(OpenCsvProductPresentation.currencyName(
            currency: "USD",
            assetId: assetId,
        ) == "Test USD")
        #expect(OpenCsvProductPresentation.currencyName(
            currency: "USD",
            assetId: String(repeating: "00", count: 32),
        ) == "USD")
        #expect(OpenCsvProductPresentation.currencyName(
            currency: "EUR",
            assetId: assetId,
        ) == "EUR")

        let policy = try #require(OpenCsvReviewedUsdIssuers.policies(for: "signet").first)
        let instrument = OpenCsvInstrumentRecord(
            assetId: assetId,
            trustState: "trusted_configuration",
            profile: "trusted_test_usd_v2",
            issuerPriority: policy.priority,
            manifest: policy.manifest,
        )
        #expect(OpenCsvProductPresentation.currencyName(
            network: "signet",
            instruments: [instrument],
        ) == "Test USD")
        #expect(OpenCsvProductPresentation.currencyName(
            network: "mainnet",
            instruments: [instrument],
        ) == "USD")

        let lookalike = OpenCsvInstrumentRecord(
            assetId: assetId,
            trustState: "trusted_configuration",
            profile: "trusted_test_usd_v2",
            issuerPriority: policy.priority,
            manifest: OpenCsvInstrumentManifest(
                terms: OpenCsvInstrumentTerms(
                    network: "signet",
                    displayName: "Lookalike",
                    unitCode: "USD",
                    decimals: 6,
                    issuerName: "Not reviewed",
                    termsUri: "https://example.invalid",
                    redemptionSummary: "not reviewed",
                    testOnly: true,
                ),
                genesis: policy.manifest.genesis,
            ),
        )
        #expect(OpenCsvProductPresentation.currencyName(
            network: "signet",
            instruments: [lookalike],
        ) == "USD")
    }
}

/// Exercises the real Rust FFI linked into SignalServiceKit.
struct OpenCsvClientFfiTest {
    private func accountConfig(backupVerified: Bool = false) -> OpenCsvAccountConfig {
        OpenCsvAccountConfig(
            network: "regtest",
            esploraUrl: "http://127.0.0.1:3002",
            peers: ["127.0.0.1:18444"],
            verificationPeers: ["127.0.0.1:18444"],
            role: .primary,
            backupVerified: backupVerified,
            requiredConfirmations: 1,
        )
    }

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
    func reviewedV2ManifestMatchesRustAssetIdentity() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencsv-v2-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = try OpenCsvAccountWallet(
            config: OpenCsvAccountConfig(
                network: "signet",
                esploraUrl: "https://mempool.space/signet/api",
                peers: [],
                verificationPeers: [],
                role: .primary,
                backupVerified: false,
                usdIssuers: OpenCsvReviewedUsdIssuers.policies(for: "signet"),
            ),
            accountRoot: Data(repeating: 41, count: 32),
            deviceBinding: Data(repeating: 42, count: 32),
            databasePath: directory.appendingPathComponent("account-v2.sqlite").path,
        )
        let status = try account.status()
        #expect(status.deploymentId == "opencsv-test-usd-v2")
        let instrument = try #require(status.instruments.first)
        #expect(instrument.assetId == OpenCsvReviewedUsdIssuers.signetTestUsdAssetId)
        #expect(instrument.profile == "trusted_test_usd_v2")
        #expect(instrument.trustState == "trusted_configuration")
    }

    @Test
    func accountInspectionPreservesStableInvalidConsignmentReason() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencsv-invalid-inspection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = try OpenCsvAccountWallet(
            config: accountConfig(),
            accountRoot: Data(repeating: 43, count: 32),
            deviceBinding: Data(repeating: 44, count: 32),
            databasePath: directory.appendingPathComponent("account.sqlite").path,
        )

        do {
            _ = try account.inspect(blob: Data([0, 1, 2]))
            Issue.record("a malformed consignment must not produce an inspection")
        } catch let OpenCsvClientError.ffi(message) {
            #expect(message.hasPrefix("invalid_consignment:"))
        } catch {
            Issue.record("unexpected malformed-consignment error: \(error)")
        }
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

    @Test
    func accountWalletOpensWithNoCallerSelectedBitcoinState() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencsv-account-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("account.sqlite").path
        let root = Data(repeating: 8, count: 32)
        let binding = Data(repeating: 9, count: 32)

        do {
            let wallet = try OpenCsvAccountWallet(
                config: accountConfig(),
                accountRoot: root,
                deviceBinding: binding,
                databasePath: databasePath,
            )
            let status = try wallet.status()
            #expect(status.role == .primary)
            #expect(status.deviceBinding.status == "bound")
            #expect(!status.backupVerified)
            #expect(!status.writeEnabled)
            #expect(status.feeReserve.totalSats == 0)
            #expect(status.depositAddress.hasPrefix("bcrt1"))
            let checkpoint = try wallet.checkpoint()
            #expect(checkpoint.checkpoint.version == OpenCsvReviewedUsdIssuers.testUsdCheckpointVersion)
            #expect(checkpoint.checkpoint.deviceBindingCommitment == status.deviceBinding.commitment)
        }

        // Losing a ThisDeviceOnly binding is sticky. Reopening once without
        // it, then supplying a new value, must never re-arm the same DB.
        do {
            let restored = try OpenCsvAccountWallet(
                config: accountConfig(backupVerified: true),
                accountRoot: root,
                deviceBinding: nil,
                databasePath: databasePath,
            )
            let restoredStatus = try restored.status()
            #expect(restoredStatus.deviceBinding.status == "mismatch_read_only")
            #expect(!restoredStatus.writeEnabled)
        }
        do {
            let replacementAttempt = try OpenCsvAccountWallet(
                config: accountConfig(backupVerified: true),
                accountRoot: root,
                deviceBinding: Data(repeating: 10, count: 32),
                databasePath: databasePath,
            )
            let replacementStatus = try replacementAttempt.status()
            #expect(replacementStatus.deviceBinding.status == "mismatch_read_only")
            #expect(!replacementStatus.writeEnabled)
        }
    }

    @Test
    func accountDatabaseRejectsCrossNetworkReuse() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencsv-network-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("account.sqlite").path
        let root = Data(repeating: 28, count: 32)
        let binding = Data(repeating: 29, count: 32)

        _ = try OpenCsvAccountWallet(
            config: accountConfig(),
            accountRoot: root,
            deviceBinding: binding,
            databasePath: databasePath,
        )
        let mainnet = OpenCsvAccountConfig(
            network: "mainnet",
            esploraUrl: "https://mempool.space/api",
            peers: ["seed.bitcoin.sipa.be:8333", "dnsseed.bluematt.me:8333"],
            verificationPeers: ["seed.bitcoin.sipa.be:8333", "dnsseed.bluematt.me:8333"],
            role: .primary,
            backupVerified: false,
            requiredConfirmations: 6,
        )
        do {
            _ = try OpenCsvAccountWallet(
                config: mainnet,
                accountRoot: root,
                deviceBinding: binding,
                databasePath: databasePath,
            )
            Issue.record("a durable account database must never change Bitcoin networks")
        } catch let OpenCsvClientError.ffi(message) {
            #expect(message.contains("database deployment opencsv-test-usd-v2 cannot open as opencsv-mainnet"))
        } catch {
            Issue.record("unexpected network-reuse error: \(error)")
        }
    }

    @Test
    func accountCheckpointRestoresOnlyIntoMatchingReadOnlyAccount() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencsv-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = Data(repeating: 18, count: 32)
        let binding = Data(repeating: 19, count: 32)
        let original = try OpenCsvAccountWallet(
            config: accountConfig(),
            accountRoot: root,
            deviceBinding: binding,
            databasePath: directory.appendingPathComponent("original.sqlite").path,
        )
        let originalStatus = try original.status()
        let checkpointJson = try original.checkpointJson()
        let commitment = try #require(originalStatus.deviceBinding.commitment)
        let restored = try OpenCsvAccountWallet(
            config: OpenCsvAccountConfig(
                network: "regtest",
                esploraUrl: "http://127.0.0.1:3002",
                peers: ["127.0.0.1:18444"],
                verificationPeers: ["127.0.0.1:18444"],
                role: .primary,
                backupVerified: false,
                expectedDeviceBindingCommitment: commitment,
                requiredConfirmations: 1,
            ),
            accountRoot: root,
            deviceBinding: nil,
            databasePath: directory.appendingPathComponent("restored.sqlite").path,
        )
        let status = try restored.restoreCheckpoint(checkpointJson)
        #expect(status.rootFingerprint == originalStatus.rootFingerprint)
        #expect(status.deviceBinding.status == "mismatch_read_only")
        #expect(status.backupVerified)
        #expect(!status.writeEnabled)
        // The same exact backup is idempotent.
        #expect(try restored.restoreCheckpoint(checkpointJson).rootFingerprint == status.rootFingerprint)
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

        let db = makeOpenCsvTestDatabase()
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

    @Test
    func mintedVerdictIsAnIssuerCreditNotAnOutgoingDebit() {
        let record = OpenCsvVerdictRecord(
            mintedAmount: 100,
            currency: "USD",
            assetId: "asset",
            consignmentId: "mint-consignment",
            date: Date(timeIntervalSince1970: 0),
        )
        #expect(record.direction == .minted)
        #expect(record.amount == 100)
        #expect(record.isVerified)
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

    @Test
    func freshSignetWalletUsesReviewedPeersWithoutSingleIndexerDowngrade() {
        let defaults = OpenCsvPayments.effectiveSpvPeers(configured: [], network: "signet")
        #expect(defaults == [
            "176.9.8.81:38333",
            "180.189.55.15:38333",
            "185.209.178.165:38333",
        ])
        #expect(OpenCsvPayments.chainViewPlan(peerCount: defaults.count, indexerCount: 1) == .selfScan)

        let explicit = ["node.example:38333"]
        #expect(OpenCsvPayments.effectiveSpvPeers(configured: explicit, network: "signet") == explicit)
        #expect(OpenCsvPayments.effectiveSpvPeers(configured: [], network: "mainnet").isEmpty)
    }

    /// Required pinned APIs gate zero-confirmation forwarding, not settlement
    /// after the phone-owned verified scan proves the exact anchor in a block.
    @Test
    func verifiedScanRechecksBroadcastUnobservedOperations() {
        #expect(OpenCsvPayments.shouldRefreshOperationSpv(state: "broadcast_unobserved"))
        #expect(OpenCsvPayments.shouldRefreshOperationSpv(state: "mempool"))
        #expect(OpenCsvPayments.shouldRefreshOperationSpv(state: "confirmed"))
        #expect(OpenCsvPayments.shouldRefreshOperationSpv(state: "consignment_delivered"))
        #expect(!OpenCsvPayments.shouldRefreshOperationSpv(state: "signed_persisted"))
        #expect(!OpenCsvPayments.shouldRefreshOperationSpv(state: "cancelled"))
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

    /// A live send found the confirmed spend scan at N while Rust's
    /// independently verified funding view had just advanced to N+1. Only
    /// the stable freshness reason may invalidate the cached launch receipt;
    /// definitive protocol and database failures remain final.
    @Test
    func fundingTipRaceIsTheOnlyProofGateRetry() {
        #expect(OpenCsvPayments.isChainVerificationUnavailable(
            OpenCsvClientError.ffi("chain_verification_unavailable"),
        ))
        #expect(OpenCsvPayments.isChainVerificationUnavailable(
            OpenCsvClientError.ffi(
                "chain_verification_unavailable: confirmed spend scan tip 10 is behind funding tip 11",
            ),
        ))
        #expect(!OpenCsvPayments.isChainVerificationUnavailable(
            OpenCsvClientError.ffi("stale_chain_state: nullifier conflict"),
        ))
        #expect(!OpenCsvPayments.isChainVerificationUnavailable(
            OpenCsvClientError.ffi("database_error: chain_verification_unavailable in detail"),
        ))
        #expect(!OpenCsvPayments.isChainVerificationUnavailable(
            OpenCsvPaymentsError.chainVerificationUnavailable,
        ))
    }

    /// Archived or unknown instruments are a final local product-policy
    /// result, not a network retry. This keeps v1 attachments visible in
    /// message history without ever crediting or relabeling them as v2.
    @Test
    func receiverRejectsUnreviewedAssetsBeforeChainWork() {
        let reviewed = OpenCsvConsignmentInspection(
            consignmentId: "reviewed-consignment",
            paymentId: "reviewed-payment",
            anchorTxid: String(repeating: "11", count: 32),
            anchorHeight: 0,
            anchorPosition: 0,
            assetIds: ["reviewed"],
            allAssetsReviewed: true,
            unreviewedAssetIds: [],
            rejectionReason: nil,
        )
        #expect(OpenCsvPayments.receiverAssetRejectionReason(reviewed) == nil)

        let archived = OpenCsvConsignmentInspection(
            consignmentId: "archived-consignment",
            paymentId: "archived-payment",
            anchorTxid: String(repeating: "22", count: 32),
            anchorHeight: 0,
            anchorPosition: 0,
            assetIds: ["archived-v1"],
            allAssetsReviewed: false,
            unreviewedAssetIds: ["archived-v1"],
            rejectionReason: "asset_not_reviewed",
        )
        #expect(OpenCsvPayments.receiverAssetRejectionReason(archived) == "asset_not_reviewed")

        let contradictory = OpenCsvConsignmentInspection(
            consignmentId: "contradictory-consignment",
            paymentId: "contradictory-payment",
            anchorTxid: String(repeating: "33", count: 32),
            anchorHeight: 0,
            anchorPosition: 0,
            assetIds: ["unknown"],
            allAssetsReviewed: true,
            unreviewedAssetIds: ["unknown"],
            rejectionReason: nil,
        )
        #expect(OpenCsvPayments.receiverAssetRejectionReason(contradictory) == "asset_not_reviewed")
    }

    @Test
    func malformedConsignmentsAreTerminalButInfrastructureFailuresRetry() {
        #expect(OpenCsvPayments.terminalIncomingRejectionReason(
            OpenCsvClientError.ffi("invalid_consignment: non-canonical digest"),
        ) == "invalid_consignment")
        #expect(OpenCsvPayments.terminalIncomingRejectionReason(
            OpenCsvClientError.ffi("invalid_consignment"),
        ) == "invalid_consignment")
        #expect(OpenCsvPayments.terminalIncomingRejectionReason(
            OpenCsvClientError.ffi("chain_verification_unavailable: peers offline"),
        ) == nil)
        #expect(OpenCsvPayments.terminalIncomingRejectionReason(
            OpenCsvClientError.ffi("database_error: invalid_consignment appears only in detail"),
        ) == nil)
    }

    /// Repairs exact live failures without turning every definitive rejection
    /// into an unbounded replay: lagging views and verdicts produced before a
    /// known verifier correction are retried, current bad proofs are not.
    @Test
    func onlyMissingLagOrPreProjectionVerdictsAreRetried() throws {
        func record(status: String, reason: String?) -> OpenCsvVerdictRecord {
            OpenCsvVerdictRecord(
                verdict: OpenCsvVerdict(
                    status: status,
                    reason: reason,
                    credits: nil,
                    coins: nil,
                    anchor: nil,
                ),
                date: Date(timeIntervalSince1970: 0),
            )
        }

        #expect(OpenCsvPayments.shouldRetryStoredVerdict(nil))
        #expect(OpenCsvPayments.shouldRetryStoredVerdict(
            record(status: "rejected", reason: "AnchorNotFound"),
        ))
        #expect(OpenCsvPayments.shouldRetryStoredVerdict(
            record(
                status: "rejected",
                reason: "InsufficientConfirmations { have: 5, required: 6 }",
            ),
        ))
        #expect(!OpenCsvPayments.shouldRetryStoredVerdict(
            record(status: "rejected", reason: "NullifierConflict"),
        ))
        #expect(!OpenCsvPayments.shouldRetryStoredVerdict(
            record(status: "rejected", reason: "InvalidProof"),
        ))
        #expect(!OpenCsvPayments.shouldRetryStoredVerdict(
            record(status: "rejected", reason: "NoOwnedOutput"),
        ))
        #expect(!OpenCsvPayments.shouldRetryStoredVerdict(
            record(status: "rejected", reason: "invalid_consignment"),
        ))
        #expect(!OpenCsvPayments.shouldRetryStoredVerdict(
            record(status: "verified", reason: nil),
        ))
        let preProjectionInvalidProof = try JSONDecoder().decode(
            OpenCsvVerdictRecord.self,
            from: Data(
                #"{"status":"rejected","reason":"InvalidProof","amount":0,"direction":"thirdParty","verifiedAt":0}"#.utf8,
            ),
        )
        #expect(preProjectionInvalidProof.verificationVersion == nil)
        #expect(OpenCsvPayments.shouldRetryStoredVerdict(preProjectionInvalidProof))
        let preAccountOwnershipCheck = try JSONDecoder().decode(
            OpenCsvVerdictRecord.self,
            from: Data(
                #"{"verificationVersion":2,"status":"rejected","reason":"NoOwnedOutput","amount":0,"direction":"thirdParty","verifiedAt":0}"#.utf8,
            ),
        )
        #expect(preAccountOwnershipCheck.verificationVersion == 2)
        #expect(OpenCsvPayments.shouldRetryStoredVerdict(preAccountOwnershipCheck))
        let provisional = OpenCsvVerdictRecord(
            verdict: OpenCsvVerdict(
                status: "verified",
                reason: nil,
                credits: [],
                coins: nil,
                anchor: .init(height: 0, position: 0),
                finality: "unconfirmed",
                spendable: true,
                anchorTxid: String(repeating: "ab", count: 32),
            ),
            date: Date(timeIntervalSince1970: 0),
        )
        #expect(OpenCsvPayments.shouldRetryStoredVerdict(provisional))
    }

    /// The explorer sheet's evidence join: full snapshot entry (txid,
    /// record, ctx) at a verdict's anchor location.
    @Test
    func snapshotEntryDetailsJoin() throws {
        let snapshot = """
        {"tip_height":10,"entries":[
          {"height":3,"position":0,"txid":"aa11","ctx":"cc22","record":"dd33"}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let anchor = try decoder.decode(
            OpenCsvVerdict.Anchor.self,
            from: Data(#"{"height":3,"position":0}"#.utf8),
        )
        let entry = OpenCsvChainView.snapshotEntryDetails(fromSnapshotJson: snapshot, anchor: anchor)
        #expect(entry?.txidHex == "aa11")
        #expect(entry?.recordHex == "dd33")
        #expect(entry?.ctxHex == "cc22")

        let missing = try decoder.decode(
            OpenCsvVerdict.Anchor.self,
            from: Data(#"{"height":9,"position":9}"#.utf8),
        )
        #expect(OpenCsvChainView.snapshotEntryDetails(fromSnapshotJson: snapshot, anchor: missing) == nil)
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
        #expect(record.finality == nil)
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

    /// Persistent-client smokes, offline: config errors fail before any
    /// dial, and a bogus client id is an error — both must surface as
    /// `ffi` (infrastructure), never as verdicts.
    @Test
    func persistentClientErrorsSurfaceAsFfiErrors() {
        let config = OpenCsvChainView.ScanSyncConfig(
            network: "marsnet",
            peers: ["127.0.0.1:1"],
            cacheDir: NSTemporaryDirectory() + "opencsv-cbf-open-test",
            fromHeight: 1,
            requiredConfirmations: 6,
        )
        #expect(throws: OpenCsvClientError.self) {
            _ = try OpenCsvChainView.openCbfClient(config: config)
        }
        #expect(throws: OpenCsvClientError.self) {
            _ = try OpenCsvChainView.scanSyncWith(clientId: 999_999_999)
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

private struct OpenCsvZeroConfFixture: Decodable {
    struct Snapshot: Codable {
        struct Entry: Codable {}
        let tipHeight: UInt64
        let entries: [Entry]
    }

    let accountRootHex: String
    let deviceBindingHex: String
    let amount: UInt64
    let anchorTxid: String
    let rawTransactionHex: String
    let consignmentBase64: String
    let confirmedSnapshotJson: Snapshot
}

private final class OpenCsvOneThenMissingEsplora: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.signal.OpenCsvOneThenMissingEsplora")
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let rawTransaction: Data
    private var rawRequests = 0

    private init(rawTransaction: Data) throws {
        self.rawTransaction = rawTransaction
        self.listener = try NWListener(using: .tcp, on: .any)
    }

    static func start(rawTransaction: Data) throws -> OpenCsvOneThenMissingEsplora {
        let server = try OpenCsvOneThenMissingEsplora(rawTransaction: rawTransaction)
        server.listener.stateUpdateHandler = { [weak server] state in
            if case .ready = state {
                server?.ready.signal()
            }
        }
        server.listener.newConnectionHandler = { [weak server] connection in
            server?.handle(connection)
        }
        server.listener.start(queue: server.queue)
        guard server.ready.wait(timeout: .now() + 5) == .success else {
            server.listener.cancel()
            throw OpenCsvClientError.ffi("local Esplora fixture did not start")
        }
        return server
    }

    var url: String {
        "http://127.0.0.1:\(listener.port!.rawValue)"
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let isRawTransactionRequest = request.contains("/raw ")
            let shouldServe: Bool = self.lock.withLock {
                guard isRawTransactionRequest else { return false }
                self.rawRequests += 1
                return self.rawRequests == 1
            }
            let status = shouldServe ? "200 OK" : "404 Not Found"
            let body = shouldServe ? self.rawTransaction : Data()
            let header = "HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private func openCsvHexData(_ text: String) -> Data? {
    guard text.count.isMultiple(of: 2) else { return nil }
    var data = Data(capacity: text.count / 2)
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

/// Simulator-only field acceptance for the exact provisional trust boundary:
/// the first Esplora read serves a valid canonical parent, the next reports
/// it missing, and a database reopen must keep the credited coin frozen.
struct OpenCsvZeroConfirmationSimulatorTest {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCSV_ZERO_CONF_FIXTURE"] != nil))
    func exactParentDisappearanceFreezesImmediatelyAndDurably() throws {
        let fixtureJson = try #require(ProcessInfo.processInfo.environment["OPENCSV_ZERO_CONF_FIXTURE"])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fixture = try decoder.decode(OpenCsvZeroConfFixture.self, from: Data(fixtureJson.utf8))
        let root = try #require(openCsvHexData(fixture.accountRootHex))
        let binding = try #require(openCsvHexData(fixture.deviceBindingHex))
        let rawTransaction = try #require(openCsvHexData(fixture.rawTransactionHex))
        let consignment = try #require(Data(base64Encoded: fixture.consignmentBase64))
        let snapshotEncoder = JSONEncoder()
        snapshotEncoder.keyEncodingStrategy = .convertToSnakeCase
        let snapshotJson = String(decoding: try snapshotEncoder.encode(fixture.confirmedSnapshotJson), as: UTF8.self)
        let server = try OpenCsvOneThenMissingEsplora.start(rawTransaction: rawTransaction)
        defer { server.stop() }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencsv-zero-conf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("account.sqlite").path
        let config = OpenCsvAccountConfig(
            network: "regtest",
            esploraUrl: server.url,
            peers: ["127.0.0.1:19444"],
            verificationPeers: ["127.0.0.1:19444"],
            verificationTimeoutSecs: 5,
            maxVerificationBlocks: 256,
            role: .primary,
            backupVerified: false,
            requiredConfirmations: 1,
            parallelRequests: 1,
        )

        var wallet: OpenCsvAccountWallet? = try OpenCsvAccountWallet(
            config: config,
            accountRoot: root,
            deviceBinding: binding,
            databasePath: databasePath,
        )
        let accepted = try wallet!.verifyUnconfirmed(blob: consignment, confirmedSnapshotJson: snapshotJson)
        #expect(accepted.isVerified)
        #expect(accepted.finality == "unconfirmed")
        #expect(accepted.spendable == true)
        #expect(accepted.anchorTxid == fixture.anchorTxid)
        #expect(try wallet!.status().assets.reduce(0) { $0 + $1.amount } == fixture.amount)

        do {
            _ = try wallet!.verifyUnconfirmed(blob: consignment, confirmedSnapshotJson: snapshotJson)
            Issue.record("a missing exact parent must freeze rather than re-credit")
        } catch let OpenCsvClientError.ffi(message) {
            #expect(message.contains("not currently observed"))
        }
        #expect(try wallet!.status().assets.isEmpty)

        wallet = nil
        let reopened = try OpenCsvAccountWallet(
            config: config,
            accountRoot: root,
            deviceBinding: binding,
            databasePath: databasePath,
        )
        #expect(try reopened.status().assets.isEmpty)
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
        let env = ProcessInfo.processInfo.environment
        let peer = env["OPENCSV_REGTEST_PEER"] ?? "127.0.0.1:18444"
        let cacheDir = env["OPENCSV_REGTEST_CACHE_KEY"].map { NSTemporaryDirectory() + $0 }
            ?? NSTemporaryDirectory() + "opencsv-scan-regtest-\(UUID().uuidString)"
        let expectsProcessResume = env["OPENCSV_REGTEST_EXPECT_RESUME"] == "1"
        let result = try OpenCsvChainView.scanSync(config: .init(
            network: "regtest",
            peers: [peer],
            cacheDir: cacheDir,
            fromHeight: 1,
            requiredConfirmations: 1,
        ))
        #expect(result.tipHeight > 0)
        if expectsProcessResume {
            #expect(result.filtersBytes == 0, "a relaunched process must reuse the durable filter cache")
        } else {
            #expect(result.filtersBytes > 0, "a real sync walks real filter bytes")
        }
        // Live diagnostic for the log: the honest bandwidth numbers.
        print(
            "OPENCSV_REGTEST scan sync: tip \(result.tipHeight), "
                + "anchors \(result.anchors), filters \(result.filtersBytes) B, "
                + "blocks \(result.blocksBytes) B",
        )

        // When the host chain carries marker-bearing anchor transactions
        // (OPENCSV_REGTEST_MIN_ANCHORS says how many), the filter walk
        // must discover them — that is the whole design.
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
            peers: [peer],
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
