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

        try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
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
            if let attachmentId = prepared.attachmentIdsForUpload(tx: tx).first {
                OpenCsvPayments.shared.setOutgoingVerdict(verdict, attachmentId: attachmentId, tx: tx)
            } else {
                owsFailDebug("OpenCSV consignment message has no attachment to key its verdict by")
            }
            _ = ThreadUtil.enqueueMessagePromise(message: prepared, transaction: tx)
            try OpenCsvPayments.shared.clearDelivered(id: delivery.id, tx: tx)
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

    private static func retryPending() {
        retryQueue.enqueue {
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

enum OpenCsvDeliveryError: Error {
    /// The conversation the payment was sent in no longer exists.
    case threadMissing
}
