//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Recognises OpenCSV consignment attachments, matching the conventions of
/// the `opencsv` CLI's Signal transport (`opencsv-signal`): a file named
/// `opencsv-consignment.bin`, or an opaque binary attachment whose message
/// body starts with the `OpenCSV consignment` marker.
public enum OpenCsvAttachmentDetector {
    public static let consignmentFilename = "opencsv-consignment.bin"
    public static let bodyMarkerPrefix = "OpenCSV consignment"
    public static let consignmentMimeType = "application/octet-stream"

    /// Decide whether an attachment carries an OpenCSV consignment.
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
}
