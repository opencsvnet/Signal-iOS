//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit
import UniformTypeIdentifiers

/// Minimal OpenCSV payment send sheet (dev-flag prototype): shows the
/// wallet's balance and receiving key, takes an amount and the recipient's
/// owner key, proves + anchors the transfer, and delivers the consignment
/// through the normal message pipeline as an `opencsv-consignment.bin`
/// attachment. Also exposes the anchor-server URL setting — the one piece
/// of configuration the wallet needs (never hardcoded).
class OpenCsvSendPaymentSheet: OWSViewController {

    private let thread: TSThread

    private let balanceLabel = UILabel()
    private let ownerLabel = UILabel()
    private let anchorServerField = UITextField()
    private let recipientField = UITextField()
    private let amountField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let shareKeyButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    init(thread: TSThread) {
        self.thread = thread
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = OWSLocalizedString(
            "OPENCSV_SEND_TITLE",
            comment: "Title of the OpenCSV payment send sheet.",
        )
        view.backgroundColor = Theme.backgroundColor
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(didTapCancel),
        )

        balanceLabel.font = .dynamicTypeTitle2
        balanceLabel.adjustsFontSizeToFitWidth = true

        ownerLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ownerLabel.numberOfLines = 2
        ownerLabel.lineBreakMode = .byCharWrapping
        ownerLabel.isUserInteractionEnabled = true
        ownerLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(didTapOwnerKey)),
        )

        for (field, placeholderKey, placeholderComment) in [
            (
                anchorServerField,
                "OPENCSV_SEND_ANCHOR_SERVER_PLACEHOLDER",
                "Placeholder for the anchor server URL field in the OpenCSV send sheet.",
            ),
            (
                recipientField,
                "OPENCSV_SEND_RECIPIENT_PLACEHOLDER",
                "Placeholder for the recipient owner key field in the OpenCSV send sheet.",
            ),
            (
                amountField,
                "OPENCSV_SEND_AMOUNT_PLACEHOLDER",
                "Placeholder for the amount field in the OpenCSV send sheet.",
            ),
        ] {
            field.placeholder = OWSLocalizedString(placeholderKey, comment: placeholderComment)
            field.borderStyle = .roundedRect
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        amountField.keyboardType = .numberPad
        // Persist the anchor server as soon as it is entered: the receive
        // pipeline needs it before the first consignment arrives.
        anchorServerField.addTarget(self, action: #selector(anchorServerChanged), for: .editingDidEnd)

        sendButton.setTitle(
            OWSLocalizedString(
                "OPENCSV_SEND_BUTTON",
                comment: "Button that proves and sends an OpenCSV payment.",
            ),
            for: .normal,
        )
        sendButton.titleLabel?.font = .dynamicTypeHeadline
        sendButton.addTarget(self, action: #selector(didTapSend), for: .touchUpInside)

        shareKeyButton.setTitle(
            OWSLocalizedString(
                "OPENCSV_SEND_SHARE_KEY_BUTTON",
                comment: "Button that posts this wallet's receiving key into the chat.",
            ),
            for: .normal,
        )
        shareKeyButton.titleLabel?.font = .dynamicTypeBody
        shareKeyButton.addTarget(self, action: #selector(didTapShareKey), for: .touchUpInside)

        statusLabel.font = .dynamicTypeFootnote
        statusLabel.textColor = Theme.secondaryTextAndIconColor
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [
            balanceLabel,
            ownerLabel,
            anchorServerField,
            recipientField,
            amountField,
            sendButton,
            shareKeyButton,
            statusLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        refreshWalletSummary()
    }

    private func refreshWalletSummary() {
        setStatus(OWSLocalizedString(
            "OPENCSV_SEND_STATUS_LOADING",
            comment: "Status shown while the OpenCSV wallet is loading.",
        ))
        let threadUniqueId = thread.uniqueId
        Task {
            // Give unverified consignments in this chat another chance
            // (e.g. ones that arrived before the anchor server was set).
            await OpenCsvPayments.shared.retryPendingVerifications(threadUniqueId: threadUniqueId)
            do {
                let summary = try await OpenCsvPayments.shared.walletSummary()
                let balances = summary.balances
                    .map { "\($0.amount) \($0.currency ?? $0.assetId.prefix(8).lowercased())" }
                    .joined(separator: ", ")
                self.balanceLabel.text = balances.isEmpty
                    ? OWSLocalizedString(
                        "OPENCSV_SEND_NO_BALANCE",
                        comment: "Shown in the OpenCSV send sheet when the wallet is empty.",
                    )
                    : balances
                self.ownerLabel.text = summary.owner
                self.anchorServerField.text = summary.anchorServerUrl?.absoluteString
                self.prefillRecipient(ownKey: summary.owner)
                self.setStatus("")
            } catch {
                self.setStatus("\(error)")
            }
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.text = text
    }

    /// Prefill the recipient from the newest address announced in this
    /// chat (payments carry the sender's key; "Share my key" posts it).
    private func prefillRecipient(ownKey: String) {
        guard recipientField.text?.strippedOrNil == nil else { return }
        let thread = self.thread
        let found: String? = SSKEnvironment.shared.databaseStorageRef.read { tx in
            var found: String?
            var scanned = 0
            try? InteractionFinder(threadUniqueId: thread.uniqueId)
                .enumerateInteractionsForConversationView(rowIdFilter: .newest, tx: tx) { interaction in
                    scanned += 1
                    if
                        let body = (interaction as? TSMessage)?.body,
                        let key = OpenCsvAttachmentDetector.parseAddress(fromBody: body),
                        key != ownKey
                    {
                        found = key
                        return false
                    }
                    return scanned < 100
                }
            return found
        }
        if let found {
            recipientField.text = found
            setStatus(OWSLocalizedString(
                "OPENCSV_SEND_RECIPIENT_FROM_CHAT",
                comment: "Status shown when the recipient key was prefilled from the chat.",
            ))
        }
    }

    @objc
    private func didTapShareKey() {
        guard let owner = ownerLabel.text?.strippedOrNil else { return }
        let thread = self.thread
        ThreadUtil.enqueueMessage(
            body: MessageBody(
                text: OpenCsvAttachmentDetector.addressAnnouncement(owner: owner),
                ranges: .empty,
            ),
            thread: thread,
        )
        setStatus(OWSLocalizedString(
            "OPENCSV_SEND_KEY_SHARED",
            comment: "Confirmation that the wallet's receiving key was posted to the chat.",
        ))
    }

    @objc
    private func didTapCancel() {
        dismiss(animated: true)
    }

    @objc
    private func anchorServerChanged() {
        let url = anchorServerField.text?.strippedOrNil
        Task {
            await OpenCsvPayments.shared.setAnchorServerUrl(url)
        }
    }

    @objc
    private func didTapOwnerKey() {
        UIPasteboard.general.string = ownerLabel.text
        setStatus(OWSLocalizedString(
            "OPENCSV_SEND_KEY_COPIED",
            comment: "Confirmation that the wallet's receiving key was copied.",
        ))
    }

    @objc
    private func didTapSend() {
        guard let recipient = recipientField.text?.strippedOrNil else {
            setStatus(OWSLocalizedString(
                "OPENCSV_SEND_ERROR_NO_RECIPIENT",
                comment: "Error shown when the OpenCSV recipient key field is empty.",
            ))
            return
        }
        guard let amountText = amountField.text, let amount = UInt64(amountText), amount > 0 else {
            setStatus(OWSLocalizedString(
                "OPENCSV_SEND_ERROR_BAD_AMOUNT",
                comment: "Error shown when the OpenCSV amount field is not a positive integer.",
            ))
            return
        }
        sendButton.isEnabled = false
        setStatus(OWSLocalizedString(
            "OPENCSV_SEND_STATUS_PROVING",
            comment: "Status shown while an OpenCSV payment proof is being generated.",
        ))

        let anchorServer = anchorServerField.text?.strippedOrNil
        let thread = self.thread
        Task {
            do {
                await OpenCsvPayments.shared.setAnchorServerUrl(anchorServer)
                let (blob, body) = try await OpenCsvPayments.shared.sendPayment(
                    toOwnerHex: recipient,
                    amount: amount,
                )
                try self.enqueueConsignmentMessage(blob: blob, body: body, thread: thread)
                self.dismiss(animated: true)
            } catch {
                self.sendButton.isEnabled = true
                self.setStatus("\(error)")
            }
        }
    }

    private func enqueueConsignmentMessage(blob: Data, body: String, thread: TSThread) throws {
        let dataSource = try DataSourcePath(writingTempFileData: blob, fileExtension: "bin")
        dataSource.sourceFilename = OpenCsvAttachmentDetector.consignmentFilename
        let previewable = try PreviewableAttachment.genericAttachment(
            dataSource: dataSource,
            dataUTI: UTType.data.identifier,
            attachmentLimits: OutgoingAttachmentLimits.currentLimits(),
        )
        Task {
            // Image quality is irrelevant for an opaque binary attachment.
            let sendable = try await SendableAttachment.forPreviewableAttachment(
                previewable,
                imageQualityLevel: .one,
            )
            ThreadUtil.enqueueMessage(
                body: MessageBody(text: body, ranges: .empty),
                attachments: ([sendable], isViewOnce: false),
                thread: thread,
            )
        }
    }
}
