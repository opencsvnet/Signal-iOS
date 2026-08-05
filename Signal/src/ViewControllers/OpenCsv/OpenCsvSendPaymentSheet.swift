//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// The OpenCSV send sheet: an amount, who it goes to, and a button.
///
/// Configuration is not sending — the wallet screen (nav bar) holds the
/// receiving key, balance detail, and advanced chain settings. Payments
/// happen in conversations, so the recipient is resolved from the key
/// announced in this chat, never typed: hex does not appear here.
class OpenCsvSendPaymentSheet: OWSViewController {

    private let thread: TSThread

    private let balanceLabel = UILabel()
    private let amountField = UITextField()
    private let recipientLabel = UILabel()
    private let batchRecipientsLabel = UILabel()
    private let addRecipientButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let shareKeyButton = UIButton(type: .system)
    private let errorLabel = UILabel()

    private var resolvedRecipientKey: String?
    private var walletOwnerKey: String?
    private var usdBalances = [OpenCsvCredit]()
    private var usdInstruments = [OpenCsvInstrumentRecord]()
    private var hasUsdBalance = false
    private var batchDrafts = [BatchDraft]()

    private struct BatchDraft {
        let thread: TSThread
        let recipient: String
        let name: String
        let amount: UInt64
    }

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
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: OWSLocalizedString(
                "OPENCSV_SEND_VIEW_WALLET",
                comment: "Button that opens the OpenCSV wallet from the send sheet.",
            ),
            style: .plain,
            target: self,
            action: #selector(didTapWallet),
        )

        balanceLabel.font = .dynamicTypeFootnote
        balanceLabel.textColor = Theme.secondaryTextAndIconColor
        balanceLabel.numberOfLines = 0
        balanceLabel.text = OWSLocalizedString(
            "OPENCSV_SEND_STATUS_LOADING",
            comment: "Status shown while the OpenCSV wallet is loading.",
        )

        amountField.font = UIFont.dynamicTypeLargeTitle1Clamped.withSize(44)
        amountField.keyboardType = .decimalPad
        amountField.textAlignment = .center
        amountField.placeholder = "0.00 USD"
        amountField.isHidden = true

        recipientLabel.font = .dynamicTypeBody
        recipientLabel.textAlignment = .center
        recipientLabel.numberOfLines = 0
        recipientLabel.isHidden = true

        batchRecipientsLabel.font = .dynamicTypeFootnote
        batchRecipientsLabel.textColor = Theme.secondaryTextAndIconColor
        batchRecipientsLabel.textAlignment = .center
        batchRecipientsLabel.numberOfLines = 0
        batchRecipientsLabel.isHidden = true

        addRecipientButton.setTitle(
            OWSLocalizedString(
                "OPENCSV_SEND_ADD_RECIPIENT",
                comment: "Button that adds another recipient to the same Bitcoin transaction.",
            ),
            for: .normal,
        )
        addRecipientButton.titleLabel?.font = .dynamicTypeBody
        addRecipientButton.addTarget(self, action: #selector(didTapAddRecipient), for: .touchUpInside)
        addRecipientButton.isHidden = true

        sendButton.titleLabel?.font = .dynamicTypeHeadline
        sendButton.addTarget(self, action: #selector(didTapSend), for: .touchUpInside)
        setSendState(.ready)
        sendButton.isHidden = true

        shareKeyButton.setTitle(
            OWSLocalizedString(
                "OPENCSV_SEND_SHARE_KEY_BUTTON",
                comment: "Button that posts this wallet's receiving key into the chat.",
            ),
            for: .normal,
        )
        shareKeyButton.titleLabel?.font = .dynamicTypeBody
        shareKeyButton.addTarget(self, action: #selector(didTapShareKey), for: .touchUpInside)
        shareKeyButton.isHidden = true

        errorLabel.font = .dynamicTypeFootnote
        errorLabel.textColor = .ows_accentRed
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [
            balanceLabel,
            amountField,
            recipientLabel,
            batchRecipientsLabel,
            addRecipientButton,
            sendButton,
            shareKeyButton,
            errorLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        refresh()
    }

    // MARK: - State

    private enum SendState {
        case ready
        case checkingWallet
        case proving
        case protectingRecovery
        case broadcasting
        case queued
        case sent
    }

    private func setSendState(_ state: SendState) {
        let (key, comment, enabled): (String, String, Bool) = {
            switch state {
            case .ready:
                return (
                    "OPENCSV_SEND_BUTTON",
                    "Button that proves and sends an OpenCSV payment.",
                    true,
                )
            case .checkingWallet:
                return (
                    "OPENCSV_SEND_STATE_CHECKING_WALLET",
                    "Send button state while the fee wallet and current chain state are checked.",
                    false,
                )
            case .proving:
                return (
                    "OPENCSV_SEND_STATE_PROVING",
                    "Send button state while the payment proof is generated on this phone.",
                    false,
                )
            case .protectingRecovery:
                return (
                    "OPENCSV_SEND_STATE_PROTECTING_RECOVERY",
                    "Send button state while the wallet recovery checkpoint is protected.",
                    false,
                )
            case .broadcasting:
                return (
                    "OPENCSV_SEND_STATE_BROADCASTING",
                    "Send button state while the Bitcoin record is broadcast.",
                    false,
                )
            case .queued:
                return (
                    "OPENCSV_SEND_STATE_QUEUED",
                    "Send button state after a durable payment is queued for background proving.",
                    false,
                )
            case .sent:
                return (
                    "OPENCSV_SEND_STATE_SENT",
                    "Send button state after the payment has been sent.",
                    false,
                )
            }
        }()
        sendButton.setTitle(OWSLocalizedString(key, comment: comment), for: .normal)
        sendButton.isEnabled = enabled
    }

    private func refresh() {
        let threadUniqueId = thread.uniqueId
        Task {
            do {
                // Show the durable wallet immediately. Verification and fee
                // refresh continue after the send form is usable.
                self.render(try await OpenCsvPayments.shared.walletSummary(), isUpdating: true)
                await OpenCsvPayments.shared.retryPendingVerifications(threadUniqueId: threadUniqueId)
                async let accountSync = try? await OpenCsvPayments.shared.syncAccount()
                async let scanSync = OpenCsvPayments.shared.scanSyncIfNeeded()
                _ = await (accountSync, scanSync)
                self.render(try await OpenCsvPayments.shared.walletSummary(), isUpdating: false)
            } catch {
                self.showError("\(error)")
            }
        }
    }

    private func render(_ summary: OpenCsvPayments.WalletSummary, isUpdating: Bool) {
        let trustedUsd = summary.instruments.filter {
            $0.profile == "trusted_usd_v1"
                && $0.trustState == "trusted_configuration"
                && $0.manifest?.terms.unitCode == "USD"
                && $0.manifest?.terms.decimals == 6
        }
        let trustedIds = Set(trustedUsd.map(\.assetId))
        let usdBalances = summary.balances.filter { trustedIds.contains($0.assetId) }
        let total = usdBalances.reduce(UInt64(0)) { partial, credit in
            let (combined, overflow) = partial.addingReportingOverflow(credit.amount)
            return overflow ? UInt64.max : combined
        }
        let balance = total == 0
            ? OWSLocalizedString(
                "OPENCSV_SEND_EMPTY_STATE",
                comment: "Explanation shown in the OpenCSV send sheet when the wallet has no assets.",
            )
            : String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "OPENCSV_SEND_BALANCE_FORMAT",
                    comment: "Balance line on the send sheet. Embeds {{ the balance }}.",
                ),
                "\(OpenCsvUsdAmount.format(total)) USD",
            )
        let refreshing = OWSLocalizedString(
            "OPENCSV_SEND_REFRESHING_SAVED_STATE",
            comment: "Status below the cached balance while the send sheet refreshes the wallet.",
        )
        balanceLabel.text = isUpdating ? [balance, refreshing].joined(separator: "\n") : balance
        balanceLabel.font = total == 0 ? .dynamicTypeBody : .dynamicTypeFootnote
        balanceLabel.textAlignment = total == 0 ? .center : .natural
        configureUsdProduct(usdBalances, instruments: trustedUsd)
        walletOwnerKey = summary.owner
        resolveRecipient(ownKey: summary.owner)
    }

    /// Show one USD product while retaining exact issuer instruments for
    /// deterministic selection and review. Ticker lookalikes never enter it.
    private func configureUsdProduct(
        _ balances: [OpenCsvCredit],
        instruments: [OpenCsvInstrumentRecord],
    ) {
        usdBalances = balances
        usdInstruments = instruments
        hasUsdBalance = balances.contains { $0.amount > 0 }
        renderFormAvailability()
    }

    /// An empty wallet is an empty state, not an invalid send form. Do not
    /// invite an amount or show a blue send action until an exact asset and
    /// recipient are both available.
    private func renderFormAvailability() {
        let hasAssets = hasUsdBalance
        amountField.isHidden = !hasAssets
        recipientLabel.isHidden = !hasAssets
        // Receiving never requires a balance. An empty wallet must still be
        // able to announce its key so someone else can fund it.
        shareKeyButton.isHidden = resolvedRecipientKey != nil
        sendButton.isHidden = !hasAssets || resolvedRecipientKey == nil
        addRecipientButton.isHidden = !hasAssets || resolvedRecipientKey == nil
        sendButton.isEnabled = hasAssets && resolvedRecipientKey != nil
        if !hasAssets {
            errorLabel.text = nil
            amountField.resignFirstResponder()
        }
    }

    /// The recipient is the newest key announced in this chat by someone
    /// other than us — resolved, named, and never typed.
    private func resolveRecipient(ownKey: String) {
        let found = Self.recipientAnnouncement(in: thread, ownKey: ownKey)
        if let found {
            resolvedRecipientKey = found.key
            let format = OWSLocalizedString(
                "OPENCSV_SEND_TO_FORMAT",
                comment: "Recipient line on the send sheet. Embeds {{ the recipient's name }}.",
            )
            recipientLabel.text = String.nonPluralLocalizedStringWithFormat(format, found.announcer)
        } else {
            resolvedRecipientKey = nil
            recipientLabel.text = OWSLocalizedString(
                "OPENCSV_SEND_NO_RECIPIENT_KEY",
                comment: "Shown when nobody in this chat has shared a payment key yet.",
            )
        }
        renderFormAvailability()
    }

    private static func recipientAnnouncement(
        in thread: TSThread,
        ownKey: String,
    ) -> (key: String, announcer: String)? {
        SSKEnvironment.shared.databaseStorageRef.read { tx in
            var found: (key: String, announcer: String)?
            var scanned = 0
            try? InteractionFinder(threadUniqueId: thread.uniqueId)
                .enumerateInteractionsForConversationView(rowIdFilter: .newest, tx: tx) { interaction in
                    scanned += 1
                    if
                        let message = interaction as? TSMessage,
                        let body = message.body,
                        let key = OpenCsvAttachmentDetector.parseAddress(fromBody: body),
                        key != ownKey
                    {
                        let announcer: String
                        if let incoming = message as? TSIncomingMessage {
                            announcer = SSKEnvironment.shared.contactManagerRef.displayName(
                                for: incoming.authorAddress,
                                tx: tx,
                            ).resolvedValue()
                        } else {
                            announcer = OWSLocalizedString(
                                "OPENCSV_SEND_ANNOUNCER_YOU",
                                comment: "Refers to the local user as the source of a shared OpenCSV key.",
                            )
                        }
                        found = (key, announcer)
                        return false
                    }
                    return scanned < 100
                }
            return found
        }
    }

    private func renderBatchDrafts() {
        batchRecipientsLabel.isHidden = batchDrafts.isEmpty
        batchRecipientsLabel.text = batchDrafts.map { draft in
            "+ \(draft.name): \(OpenCsvUsdAmount.format(draft.amount)) USD"
        }.joined(separator: "\n")
    }

    private func showError(_ text: String) {
        errorLabel.text = text
        setSendState(.ready)
    }

    // MARK: - Actions

    @objc
    private func didTapCancel() {
        dismiss(animated: true)
    }

    @objc
    private func didTapWallet() {
        navigationController?.pushViewController(
            OpenCsvWalletViewController(thread: thread),
            animated: true,
        )
    }

    @objc
    private func didTapShareKey() {
        Task {
            guard let owner = try? await OpenCsvPayments.shared.walletSummary().owner else { return }
            ThreadUtil.enqueueMessage(
                body: MessageBody(
                    text: OpenCsvAttachmentDetector.addressAnnouncement(owner: owner),
                    ranges: .empty,
                ),
                thread: self.thread,
            )
            self.presentToast(text: OWSLocalizedString(
                "OPENCSV_SEND_KEY_SHARED",
                comment: "Confirmation that the wallet's receiving key was posted to the chat.",
            ))
        }
    }

    @objc
    private func didTapAddRecipient() {
        guard let ownKey = walletOwnerKey else { return }
        let picker = OpenCsvBatchRecipientPickerViewController { [weak self] selectedThread in
            guard let self else { return }
            guard let found = Self.recipientAnnouncement(in: selectedThread, ownKey: ownKey) else {
                self.showError(OWSLocalizedString(
                    "OPENCSV_SEND_NO_RECIPIENT_KEY",
                    comment: "Shown when nobody in this chat has shared a payment key yet.",
                ))
                return
            }
            guard
                selectedThread.uniqueId != self.thread.uniqueId,
                !self.batchDrafts.contains(where: { $0.thread.uniqueId == selectedThread.uniqueId })
            else {
                self.showError(OWSLocalizedString(
                    "OPENCSV_SEND_DUPLICATE_RECIPIENT",
                    comment: "Error shown when a recipient is already included in this payment.",
                ))
                return
            }
            self.promptForBatchAmount(
                thread: selectedThread,
                recipient: found.key,
                name: found.announcer,
            )
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func promptForBatchAmount(thread: TSThread, recipient: String, name: String) {
        let alert = UIAlertController(
            title: OWSLocalizedString(
                "OPENCSV_SEND_ADD_RECIPIENT_AMOUNT_TITLE",
                comment: "Title asking for the USD amount for an additional batch recipient.",
            ),
            message: name,
            preferredStyle: .alert,
        )
        alert.addTextField { textField in
            textField.keyboardType = .decimalPad
            textField.placeholder = "0.00 USD"
        }
        alert.addAction(UIAlertAction(title: CommonStrings.cancelButton, style: .cancel))
        alert.addAction(UIAlertAction(
            title: OWSLocalizedString(
                "OPENCSV_SEND_ADD_RECIPIENT_CONFIRM",
                comment: "Button that stages an additional recipient before final send confirmation.",
            ),
            style: .default,
        ) { [weak self, weak alert] _ in
            guard let self else { return }
            guard
                let raw = alert?.textFields?.first?.text,
                let amount = OpenCsvUsdAmount.parse(raw),
                amount > 0
            else {
                self.showError(OWSLocalizedString(
                    "OPENCSV_SEND_ERROR_BAD_AMOUNT",
                    comment: "Error shown when the OpenCSV amount field is not a positive integer.",
                ))
                return
            }
            self.batchDrafts.append(BatchDraft(
                thread: thread,
                recipient: recipient,
                name: name,
                amount: amount,
            ))
            self.renderBatchDrafts()
        })
        present(alert, animated: true)
    }

    @objc
    private func didTapSend() {
        errorLabel.text = nil
        guard let recipient = resolvedRecipientKey else { return }
        guard
            let amountText = amountField.text,
            let amount = OpenCsvUsdAmount.parse(amountText),
            amount > 0
        else {
            showError(OWSLocalizedString(
                "OPENCSV_SEND_ERROR_BAD_AMOUNT",
                comment: "Error shown when the OpenCSV amount field is not a positive integer.",
            ))
            return
        }
        var totalAmount = amount
        for draft in batchDrafts {
            let (next, overflow) = totalAmount.addingReportingOverflow(draft.amount)
            guard !overflow else {
                showError(OWSLocalizedString(
                    "OPENCSV_SEND_ERROR_BAD_AMOUNT",
                    comment: "Error shown when the OpenCSV amount field is not a positive integer.",
                ))
                return
            }
            totalAmount = next
        }
        let selection: OpenCsvUsdSendSelection
        do {
            selection = try OpenCsvPayments.resolveUsdSendAsset(
                usdBalances,
                instruments: usdInstruments,
                amount: totalAmount,
                requestedAssetId: nil,
            )
        } catch {
            showError(Self.userFacingMessage(for: error))
            return
        }
        let issuer = selection.instrument.manifest?.terms.issuerName ?? "Unknown issuer"
        let recipientCount = batchDrafts.count + 1
        let format = OWSLocalizedString(
            "OPENCSV_SEND_REVIEW_ISSUER_FORMAT",
            comment: "USD send review naming the exact issuer. Embeds amount and issuer name.",
        )
        let recipientCountFormat = OWSLocalizedString(
            "OPENCSV_SEND_REVIEW_RECIPIENT_COUNT_FORMAT",
            comment: "USD send review recipient count. Embeds the number of recipients.",
        )
        let alert = UIAlertController(
            title: OWSLocalizedString(
                "OPENCSV_SEND_REVIEW_TITLE",
                comment: "Title reviewing an issuer-specific USD payment.",
            ),
            message: String.nonPluralLocalizedStringWithFormat(
                format,
                OpenCsvUsdAmount.format(totalAmount),
                issuer,
            ) + "\n" + String.nonPluralLocalizedStringWithFormat(
                recipientCountFormat,
                "\(recipientCount)",
            ),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: CommonStrings.cancelButton, style: .cancel))
        alert.addAction(UIAlertAction(
            title: OWSLocalizedString(
                "OPENCSV_SEND_CONFIRM",
                comment: "Button confirming an issuer-specific USD payment.",
            ),
            style: .default,
        ) { [weak self] _ in
            self?.send(
                amount: amount,
                recipient: recipient,
                assetId: selection.credit.assetId,
                batchDrafts: self?.batchDrafts ?? [],
            )
        })
        present(alert, animated: true)
    }

    private func send(
        amount: UInt64,
        recipient: String,
        assetId: String,
        batchDrafts: [BatchDraft],
    ) {
        // Only the fast durable planning boundary happens while this sheet
        // is visible. Proof, backup, broadcast, and attachment delivery
        // resume by operation id after the conversation is usable again.
        setSendState(.checkingWallet)
        let thread = self.thread
        Task {
            do {
                let first = try await OpenCsvPayments.shared.queuePayment(
                    toOwnerHex: recipient,
                    amount: amount,
                    threadUniqueId: thread.uniqueId,
                    assetIdHex: assetId,
                    progress: { [weak self] progress in
                        switch progress {
                        case .checkingWallet:
                            self?.setSendState(.checkingWallet)
                        case .generatingProof:
                            // Interactive queueing never reaches this stage;
                            // retained for the compatibility one-shot path.
                            self?.setSendState(.proving)
                        case .protectingRecovery:
                            self?.setSendState(.protectingRecovery)
                        case .broadcasting:
                            self?.setSendState(.broadcasting)
                        }
                    },
                )
                guard let batchLocalId = first.batchLocalId else {
                    throw OpenCsvClientError.decode("queued payment omitted batch membership")
                }
                try await OpenCsvDelivery.announcePending(first)
                do {
                    for draft in batchDrafts {
                        let additional = try await OpenCsvPayments.shared.addRecipientToQueuedBatch(
                            batchLocalId: batchLocalId,
                            toOwnerHex: draft.recipient,
                            amount: draft.amount,
                            threadUniqueId: draft.thread.uniqueId,
                            assetIdHex: assetId,
                        )
                        try await OpenCsvDelivery.announcePending(additional)
                    }
                    if !batchDrafts.isEmpty {
                        try await OpenCsvPayments.shared.freezeQueuedBatch(batchLocalId)
                    }
                } catch {
                    await OpenCsvPayments.shared.cancelQueuedBatch(
                        batchLocalId,
                        reason: "explicit_batch_assembly_failed",
                    )
                    OpenCsvDelivery.processPending()
                    throw error
                }
                self.setSendState(.queued)
                self.dismiss(animated: true)
                OpenCsvDelivery.processPending()
            } catch {
                // Planning either failed before insertion or cancelled the
                // exact planned id after Signal metadata could not persist.
                self.showError(Self.userFacingMessage(for: error))
            }
        }
    }

    /// Rust error strings are not user-facing copy; map the ones we model.
    private static func userFacingMessage(for error: Error) -> String {
        switch error {
        case OpenCsvPaymentsError.secureBackupRequired:
            return OWSLocalizedString(
                "OPENCSV_SEND_ERROR_BACKUP_REQUIRED",
                comment: "Error shown when Signal Secure Backup must be enabled before an OpenCSV write.",
            )
        case OpenCsvPaymentsError.secureBackupFailed:
            return OWSLocalizedString(
                "OPENCSV_SEND_ERROR_BACKUP_FAILED",
                comment: "Error shown when the wallet checkpoint could not be included in Signal Secure Backup.",
            )
        case OpenCsvPaymentsError.needTwoCoins:
            return OWSLocalizedString(
                "OPENCSV_SEND_ERROR_NEED_TWO_COINS",
                comment: "Error shown when the wallet has fewer than the two coins a transfer needs.",
            )
        case OpenCsvPaymentsError.insufficientFunds(let available):
            let format = OWSLocalizedString(
                "OPENCSV_SEND_ERROR_INSUFFICIENT_FORMAT",
                comment: "Error shown when the amount exceeds the balance. Embeds {{ available amount }}.",
            )
            return String.nonPluralLocalizedStringWithFormat(
                format,
                OpenCsvUsdAmount.format(available),
            )
        case OpenCsvPaymentsError.malformedRecipient:
            return OWSLocalizedString(
                "OPENCSV_SEND_ERROR_BAD_RECIPIENT",
                comment: "Error shown when the recipient key is not valid hex.",
            )
        case OpenCsvPaymentsError.issuerSplitRequired(let totalAvailable):
            let format = OWSLocalizedString(
                "OPENCSV_SEND_ERROR_ISSUER_SPLIT_FORMAT",
                comment: "Error shown when USD is sufficient only by combining issuers. Embeds total USD.",
            )
            return String.nonPluralLocalizedStringWithFormat(
                format,
                OpenCsvUsdAmount.format(totalAvailable),
            )
        case OpenCsvPaymentsError.sendAlreadyInProgress:
            return OWSLocalizedString(
                "OPENCSV_SEND_ERROR_IN_PROGRESS",
                comment: "Error shown when a payment is already being sent.",
            )
        case OpenCsvPaymentsError.feeReserveRequired(let minimumSats, _):
            let format = OWSLocalizedString(
                "OPENCSV_SEND_ERROR_FEE_RESERVE_FORMAT",
                comment: "Error shown when the Bitcoin fee reserve cannot fund an OpenCSV send. Embeds {{ minimum sats }}.",
            )
            return String.nonPluralLocalizedStringWithFormat(format, "\(minimumSats)")
        default:
            return OWSLocalizedString(
                "OPENCSV_SEND_ERROR_GENERIC",
                comment: "Generic error shown when an OpenCSV payment could not be sent.",
            )
        }
    }
}

private final class OpenCsvBatchRecipientPickerViewController: RecipientPickerContainerViewController,
    RecipientPickerDelegate, UsernameLinkScanDelegate
{
    private let completion: (TSThread) -> Void

    init(completion: @escaping (TSThread) -> Void) {
        self.completion = completion
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = OWSLocalizedString(
            "OPENCSV_SEND_ADD_RECIPIENT_PICKER_TITLE",
            comment: "Title of the recipient picker for a shared Bitcoin transaction.",
        )
        view.backgroundColor = .Signal.groupedBackground
        recipientPicker.allowsAddByAddress = false
        recipientPicker.shouldHideLocalRecipient = true
        recipientPicker.groupsToShow = .noGroups
        recipientPicker.delegate = self
        addRecipientPicker()
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        selectionStyleForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> UITableViewCell.SelectionStyle {
        guard let address = recipient.address, address.isValid, !address.isLocalAddress else {
            return .none
        }
        return .default
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        didSelectRecipient recipient: PickedRecipient,
    ) {
        guard let address = recipient.address, address.isValid, !address.isLocalAddress else { return }
        let thread = SSKEnvironment.shared.databaseStorageRef.write {
            TSContactThread.getOrCreateThread(withContactAddress: address, transaction: $0)
        }
        guard let navigationController else {
            completion(thread)
            return
        }
        navigationController.popViewController(animated: true)
        if let transitionCoordinator = navigationController.transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: nil) { [completion] _ in
                completion(thread)
            }
        } else {
            DispatchQueue.main.async { [completion] in
                completion(thread)
            }
        }
    }
}
