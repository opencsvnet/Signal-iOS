//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit
import UniformTypeIdentifiers

/// Delivers anchored OpenCSV consignments as Signal attachments, and
/// retries any that never made it into the send pipeline.
///
/// Anchoring is irreversible: once a transfer confirms, the consumed coins
/// are spent whether or not the recipient ever receives the consignment.
/// `OpenCsvPayments` therefore persists the bytes before delivery is
/// attempted, and this type clears that record **in the same transaction
/// that inserts the message** — never merely because a send was requested.
/// `ThreadUtil.enqueueMessage` is fire-and-forget and reports nothing, so
/// using it here would clear the record for a message that may never exist.
enum OpenCsvDelivery {

    /// Send a lightweight Signal-authenticated intent before expensive proof
    /// generation. It is intentionally ordinary text—not a consignment—and
    /// says it is nonspendable. The later proof-bearing attachment carries
    /// the same operation id.
    static func announcePending(_ operation: OpenCsvWalletStore.PendingAccountOperation) async throws {
        let body = [
            "OpenCSV payment pending",
            "\(OpenCsvUsdAmount.format(operation.amount)) \(operation.currency ?? "USD")",
            "Preparing proof on this phone. Not spendable yet.",
            "OpenCSV payment: \(operation.operationId)",
        ].joined(separator: "\n")
        let validatedBody = try await DependenciesBridge.shared.attachmentContentValidator
            .prepareOversizeTextIfNeeded(MessageBody(text: body, ranges: .empty))

        try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            let store = OpenCsvWalletStore(
                keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage,
            )
            guard
                let current = try store.pendingAccountOperations(tx: tx)
                    .first(where: { $0.operationId == operation.operationId })
            else {
                return
            }
            guard current.announcementEnqueuedAt == nil else { return }
            guard let thread = TSThread.anyFetch(uniqueId: operation.threadUniqueId, transaction: tx) else {
                throw OpenCsvDeliveryError.threadMissing
            }
            let unprepared = UnpreparedOutgoingMessage.build(
                thread: thread,
                timestamp: MessageTimestampGenerator.sharedInstance.generateTimestamp(),
                messageBody: validatedBody,
                mediaAttachments: [],
                isViewOnce: false,
                quotedReplyDraft: nil,
                linkPreviewDataSource: nil,
                transaction: tx,
            )
            let prepared = try unprepared.prepare(tx: tx)
            guard let messageId = prepared.messageForIntentDonation(tx: tx)?.uniqueId else {
                throw OpenCsvDeliveryError.messageMissing
            }
            try OpenCsvPayments.shared.markOperationAnnounced(
                operationId: operation.operationId,
                messageId: messageId,
                tx: tx,
            )
            _ = ThreadUtil.enqueueMessagePromise(message: prepared, transaction: tx)
        }
        Logger.info("announced pending OpenCSV operation \(operation.operationId)")
    }

    /// Close a previously announced intent if Rust reaches a terminal
    /// rejection. Insertion and metadata removal share one transaction, so
    /// foreground retries cannot produce duplicate failure messages.
    static func announceFailure(_ operation: OpenCsvWalletStore.PendingAccountOperation) async throws {
        guard let failureReason = operation.failureReason else { return }
        let body = [
            "OpenCSV payment failed",
            "\(OpenCsvUsdAmount.format(operation.amount)) \(operation.currency ?? "USD")",
            "Nothing is spendable from this attempt.",
            "Reason: \(failureReason)",
            "OpenCSV payment: \(operation.operationId)",
        ].joined(separator: "\n")
        let validatedBody = try await DependenciesBridge.shared.attachmentContentValidator
            .prepareOversizeTextIfNeeded(MessageBody(text: body, ranges: .empty))

        try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            let store = OpenCsvWalletStore(
                keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage,
            )
            guard
                let current = try store.pendingAccountOperations(tx: tx)
                    .first(where: { $0.operationId == operation.operationId }),
                current.failureReason != nil
            else {
                return
            }
            guard let thread = TSThread.anyFetch(uniqueId: operation.threadUniqueId, transaction: tx) else {
                throw OpenCsvDeliveryError.threadMissing
            }
            let unprepared = UnpreparedOutgoingMessage.build(
                thread: thread,
                timestamp: MessageTimestampGenerator.sharedInstance.generateTimestamp(),
                messageBody: validatedBody,
                mediaAttachments: [],
                isViewOnce: false,
                quotedReplyDraft: nil,
                linkPreviewDataSource: nil,
                transaction: tx,
            )
            let prepared = try unprepared.prepare(tx: tx)
            _ = ThreadUtil.enqueueMessagePromise(message: prepared, transaction: tx)
            try store.removePendingAccountOperation(operationId: operation.operationId, tx: tx)
        }
        Logger.info("announced failed OpenCSV operation \(operation.operationId)")
    }

    /// Insert the message carrying `delivery`, write its outgoing verdict,
    /// enqueue the send, and clear the pending record — atomically.
    ///
    /// Throws if the attachment cannot be built or the thread is gone; the
    /// pending record survives for the next attempt.
    static func deliver(_ delivery: OpenCsvWalletStore.PendingDelivery) async throws {
        guard let blob = await OpenCsvPayments.shared.beginDelivery(delivery) else {
            // Another pass has it, or its bytes are missing.
            return
        }
        defer { Task { await OpenCsvPayments.shared.endDelivery(id: delivery.id) } }

        let dataSource = try DataSourcePath(writingTempFileData: blob, fileExtension: "bin")
        dataSource.sourceFilename = OpenCsvAttachmentDetector.consignmentFilename
        let previewable = try PreviewableAttachment.genericAttachment(
            dataSource: dataSource,
            dataUTI: UTType.data.identifier,
            attachmentLimits: OutgoingAttachmentLimits.currentLimits(),
        )
        // Image quality is irrelevant for an opaque binary attachment.
        let sendable = try await SendableAttachment.forPreviewableAttachment(
            previewable,
            imageQualityLevel: .one,
        )
        let forSending = try await sendable.forSending(
            attachmentContentValidator: DependenciesBridge.shared.attachmentContentValidator,
        )
        let verdict = OpenCsvPayments.shared.outgoingVerdict(for: delivery)
        let validatedBody = try await DependenciesBridge.shared.attachmentContentValidator
            .prepareOversizeTextIfNeeded(MessageBody(text: delivery.body, ranges: .empty))

        let deliveredMessageId = try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            guard let thread = TSThread.anyFetch(uniqueId: delivery.threadUniqueId, transaction: tx) else {
                throw OpenCsvDeliveryError.threadMissing
            }
            let unprepared = UnpreparedOutgoingMessage.build(
                thread: thread,
                timestamp: MessageTimestampGenerator.sharedInstance.generateTimestamp(),
                messageBody: validatedBody,
                mediaAttachments: [forSending],
                isViewOnce: false,
                quotedReplyDraft: nil,
                linkPreviewDataSource: nil,
                transaction: tx,
            )
            // prepare(tx:) inserts the message and creates its attachment
            // rows in this same transaction, so the attachment id the
            // conversation cell will read exists before we commit.
            let prepared = try unprepared.prepare(tx: tx)
            let messageId = prepared.messageForIntentDonation(tx: tx)?.uniqueId
            if let attachmentId = prepared.attachmentIdsForUpload(tx: tx).first {
                OpenCsvPayments.shared.setOutgoingVerdict(verdict, attachmentId: attachmentId, tx: tx)
            } else {
                owsFailDebug("OpenCSV consignment message has no attachment to key its verdict by")
            }
            _ = ThreadUtil.enqueueMessagePromise(message: prepared, transaction: tx)
            try OpenCsvPayments.shared.clearDelivered(id: delivery.id, tx: tx)
            return messageId
        }
        await OpenCsvPayments.shared.acknowledgeDelivered(delivery)
        if let deliveredMessageId {
            OpenCsvPayments.shared.notifyOutgoingPaymentDelivered(
                threadUniqueId: delivery.threadUniqueId,
                messageUniqueId: deliveredMessageId,
                amount: delivery.amount,
                currency: delivery.currency,
            )
        }
        Logger.info("delivered OpenCSV consignment \(delivery.id)")
    }

    /// Re-enqueue every consignment that is anchored but undelivered.
    /// Registered at launch; also runs on each foreground.
    static func observeAppActivation(appReadiness: AppReadiness) {
        guard BuildFlags.openCsvPayments else { return }
        appReadiness.runNowOrWhenMainAppDidBecomeReadyAsync {
            retryPending()
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil,
            ) { _ in
                retryPending()
            }
        }
    }

    /// Serializes retry passes: `didBecomeActive` fires often (Control
    /// Centre, banners, permission alerts), and overlapping passes would
    /// each pick up the same still-pending record.
    private static let retryQueue = SerialTaskQueue()

    /// Start the same idempotent recovery pass immediately after the send
    /// sheet journals a payment. The caller returns to chat; this queue owns
    /// proof generation and the eventual attachment delivery.
    static func processPending() {
        retryPending()
    }

    private static func retryPending() {
        retryQueue.enqueue {
            for operation in await OpenCsvPayments.shared.operationsNeedingAnnouncement() {
                do {
                    try await announcePending(operation)
                } catch {
                    Logger.warn("could not announce pending OpenCSV operation \(operation.operationId): \(error)")
                }
            }
            // A prior send may have reached the mempool only after the
            // foreground call stopped observing it. Reconstruct its durable
            // delivery before taking the retry snapshot. Without this
            // ordering, app activation can observe an empty delivery queue,
            // spend a long time rebuilding the chain view, and create the
            // delivery only after the sole retry pass has already finished.
            await OpenCsvPayments.shared.recoverInterruptedSends()
            for operation in await OpenCsvPayments.shared.failedOperationsNeedingAnnouncement() {
                do {
                    try await announceFailure(operation)
                } catch {
                    Logger.warn("could not announce failed OpenCSV operation \(operation.operationId): \(error)")
                }
            }
            for delivery in await OpenCsvPayments.shared.deliveriesNeedingRetry() {
                do {
                    try await deliver(delivery)
                } catch {
                    // Expected while offline or mid-migration; the record
                    // stays queued and its attempt count advances.
                    Logger.warn("could not deliver OpenCSV consignment \(delivery.id): \(error)")
                }
            }
        }
    }
}

/// Resumes verification, confirmation promotion, crash recovery, and
/// consignment delivery without requiring the wallet screen to be opened.
/// BGProcessingTask timing is controlled by iOS; every pass is idempotent and
/// its next schedule is recomputed from durable wallet state.
final class OpenCsvBGProcessingTaskRunner: BGProcessingTaskRunner {
    static let taskIdentifier = "OpenCsvBGProcessingTaskRunner"
    static let logPrefix: String? = "[OpenCSV]"
    static let requiresNetworkConnectivity = true
    static let requiresExternalPower = false

    func startCondition() -> BGProcessingTaskStartCondition {
        guard BuildFlags.openCsvPayments else { return .never }
        let store = OpenCsvWalletStore(
            keychainStorage: SSKEnvironment.shared.databaseStorageRef.keychainStorage,
        )
        let urgency = DependenciesBridge.shared.db.read { store.backgroundWorkUrgency(tx: $0) }
        switch urgency {
        case .never:
            return .never
        case .immediate:
            return .asSoonAsPossible
        case .monitor:
            // Unconfirmed payments remain spendable but replacement-sensitive.
            // Ask iOS to revisit them soon without creating a foreground-style
            // polling loop. The OS may coalesce or defer this date.
            return .after(Date().addingTimeInterval(5 * 60))
        }
    }

    func run() async throws {
        guard BuildFlags.openCsvPayments else { return }
        try Task.checkCancellation()
        await OpenCsvPayments.shared.performBackgroundMaintenance()
        try Task.checkCancellation()
        for delivery in await OpenCsvPayments.shared.deliveriesNeedingRetry() {
            try Task.checkCancellation()
            do {
                try await OpenCsvDelivery.deliver(delivery)
            } catch {
                // The durable record remains and startCondition will request
                // another pass unless the bounded retry policy is exhausted.
                Logger.warn("background delivery remains retryable for \(delivery.id): \(error)")
            }
        }
    }

    func observeSchedulingRequests(appReadiness: AppReadiness) {
        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            NotificationCenter.default.addObserver(
                forName: .openCsvBackgroundWorkNeedsScheduling,
                object: nil,
                queue: nil,
            ) { [self] _ in
                Task { await scheduleBGProcessingTaskIfNeeded() }
            }
        }
    }
}

enum OpenCsvDeliveryError: Error {
    /// The conversation the payment was sent in no longer exists.
    case threadMissing
    /// A persisted text announcement unexpectedly produced no message row.
    case messageMissing
}
