//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit

/// Recognises OpenCSV consignment attachments, matching the conventions of
/// the `opencsv` CLI's Signal transport (`opencsv-signal`): a file named
/// `opencsv-consignment.bin`, or an opaque binary attachment whose message
/// body starts with the `OpenCSV consignment` marker.
public enum OpenCsvAttachmentDetector {
    public static let consignmentFilename = "opencsv-consignment.bin"
    public static let bodyMarkerPrefix = "OpenCSV consignment"
    public static let consignmentMimeType = "application/octet-stream"

    /// Decide whether a referenced attachment carries an OpenCSV
    /// consignment, resolving the owning message's body itself.
    ///
    /// Every caller must ask the same question: detection that varies by
    /// call site means an attachment can be a payment on the render path
    /// and an ordinary file on the download path, so it is verified by one
    /// and ignored by the other. The body matters because a consignment is
    /// also recognised by its marker when the filename was stripped.
    public static func isConsignment(
        referenced: ReferencedAttachment,
        tx: DBReadTransaction,
    ) -> Bool {
        isConsignment(
            sourceFilename: referenced.reference.sourceFilename,
            mimeType: referenced.attachment.mimeType,
            bodyText: owningMessageBody(of: referenced.reference, tx: tx),
        )
    }

    /// The body of the message an attachment reference belongs to, if any.
    public static func owningMessageBody(
        of reference: AttachmentReference,
        tx: DBReadTransaction,
    ) -> String? {
        guard case .message(let messageSource) = reference.owner else { return nil }
        let interaction = DependenciesBridge.shared.interactionStore.fetchInteraction(
            rowId: messageSource.messageRowId,
            tx: tx,
        )
        return (interaction as? TSMessage)?.body
    }

    /// Decide whether an attachment carries an OpenCSV consignment.
    ///
    /// Prefer the `referenced:tx:` overload; this primitive exists for the
    /// render path, which already holds the body, and for tests.
    public static func isConsignment(sourceFilename: String?, mimeType: String?, bodyText: String?) -> Bool {
        if sourceFilename?.lowercased() == consignmentFilename {
            return true
        }
        guard bodyText?.hasPrefix(bodyMarkerPrefix) == true else {
            return false
        }
        // Marker present: accept opaque binary (some clients strip the
        // content type entirely).
        switch mimeType {
        case nil, consignmentMimeType, "application/x-binary":
            return true
        default:
            return false
        }
    }

    /// The standard body accompanying an outgoing consignment attachment.
    public static func outgoingBody(byteCount: Int) -> String {
        "\(bodyMarkerPrefix) (\(byteCount) bytes)"
    }

    /// Marker line announcing a wallet's receiving key inside a message
    /// body, so wallets can prefill recipient keys from the chat itself.
    public static let addressMarkerPrefix = "OpenCSV address: "

    /// The announcement line for `owner` (64 hex chars).
    public static func addressAnnouncement(owner: String) -> String {
        "\(addressMarkerPrefix)\(owner)"
    }

    /// Extract an announced owner key from a message body, if any line
    /// carries the marker followed by 64 hex characters.
    public static func parseAddress(fromBody body: String?) -> String? {
        guard let body else { return nil }
        for line in body.components(separatedBy: "\n") {
            guard line.hasPrefix(addressMarkerPrefix) else { continue }
            let key = String(line.dropFirst(addressMarkerPrefix.count)).ows_stripped().lowercased()
            let isHex = key.count == 64 && key.allSatisfy(\.isHexDigit)
            if isHex {
                return key
            }
        }
        return nil
    }
}

/// The attachment-download seam: called when an attachment download
/// completes (from the download task runner), decides whether the new
/// stream is a consignment, and hands it to `OpenCsvPayments` for
/// verification. Deliberately tiny — all wallet logic lives in the service.
public enum OpenCsvAttachmentProcessor {
    /// Fire-and-forget: never blocks or fails the download pipeline.
    public static func processDownloadedAttachmentIfNeeded(attachmentId: Attachment.IDType) {
        guard BuildFlags.openCsvPayments else { return }
        Task {
            await OpenCsvPayments.shared.verifyDownloadedAttachmentIfNeeded(attachmentId: attachmentId)
        }
    }

    /// Settle consignments whose verification could not complete when they
    /// arrived — typically because the anchor server was unreachable.
    /// Called once the app is ready and again whenever it becomes active,
    /// so recovery never depends on the user opening a particular screen.
    public static func observeAppActivation(appReadiness: AppReadiness) {
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

    private static func retryPending() {
        Task {
            // Sync the self-scan index first — the sweep's verifications
            // consult it when SPV peers are configured. Then finish
            // anything interrupted between anchoring and finalizing before
            // sweeping: recovery can produce new consignments to deliver.
            await OpenCsvPayments.shared.scanSyncIfNeeded()
            await OpenCsvPayments.shared.recoverInterruptedSends()
            await OpenCsvPayments.shared.retryAllPendingVerifications()
        }
    }
}
