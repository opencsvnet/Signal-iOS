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
    private let sendButton = UIButton(type: .system)
    private let shareKeyButton = UIButton(type: .system)
    private let errorLabel = UILabel()

    private var resolvedRecipientKey: String?
    private var usdBalances = [OpenCsvCredit]()
    private var usdInstruments = [OpenCsvInstrumentRecord]()
    private var hasUsdBalance = false

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
        case proving
        case anchoring
        case sent
    }

    private func setSendState(_ state: SendState) {
        let (key, comment, enabled): (String, String, Bool) = {
            switch state {
            case .ready:
                return (
                    "OPENCSV_SEND_BUTTON",
                    "Button that proves and sends an OpenCSV payment.",
                    true
                )
            case .proving:
                return (
                    "OPENCSV_SEND_STATE_PROVING",
                    "Send button state while the payment proof is generated on this phone.",
                    false
                )
            case .anchoring:
                return (
                    "OPENCSV_SEND_STATE_ANCHORING",
                    "Send button state while the payment is being anchored on the chain.",
                    false
                )
            case .sent:
                return (
                    "OPENCSV_SEND_STATE_SENT",
                    "Send button state after the payment has been sent.",
                    false
                )
            }
        }()
        sendButton.setTitle(OWSLocalizedString(key, comment: comment), for: .normal)
        sendButton.isEnabled = enabled
    }

    private func refresh() {
        let threadUniqueId = thread.uniqueId
        Task {
            // Give unverified consignments in this chat another chance
            // before showing a balance that might be about to change.
            await OpenCsvPayments.shared.retryPendingVerifications(threadUniqueId: threadUniqueId)
            do {
                _ = try? await OpenCsvPayments.shared.syncAccount()
                let summary = try await OpenCsvPayments.shared.walletSummary()
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
                self.balanceLabel.text = total == 0
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
                self.balanceLabel.font = total == 0 ? .dynamicTypeBody : .dynamicTypeFootnote
                self.balanceLabel.textAlignment = total == 0 ? .center : .natural
                self.configureUsdProduct(usdBalances, instruments: trustedUsd)
                self.resolveRecipient(ownKey: summary.owner)
            } catch {
                self.showError("\(error)")
            }
        }
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
        shareKeyButton.isHidden = !hasAssets || resolvedRecipientKey != nil
        sendButton.isHidden = !hasAssets || resolvedRecipientKey == nil
        sendButton.isEnabled = hasAssets && resolvedRecipientKey != nil
        if !hasAssets {
            errorLabel.text = nil
            amountField.resignFirstResponder()
        }
    }

    /// The recipient is the newest key announced in this chat by someone
    /// other than us — resolved, named, and never typed.
    private func resolveRecipient(ownKey: String) {
        let thread = self.thread
        let found: (key: String, announcer: String)? = SSKEnvironment.shared.databaseStorageRef.read { tx in
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
        let selection: OpenCsvUsdSendSelection
        do {
            selection = try OpenCsvPayments.resolveUsdSendAsset(
                usdBalances,
                instruments: usdInstruments,
                amount: amount,
                requestedAssetId: nil,
            )
        } catch {
            showError(Self.userFacingMessage(for: error))
            return
        }
        let issuer = selection.instrument.manifest?.terms.issuerName ?? "Unknown issuer"
        let format = OWSLocalizedString(
            "OPENCSV_SEND_REVIEW_ISSUER_FORMAT",
            comment: "USD send review naming the exact issuer. Embeds amount and issuer name.",
        )
        let alert = UIAlertController(
            title: OWSLocalizedString(
                "OPENCSV_SEND_REVIEW_TITLE",
                comment: "Title reviewing an issuer-specific USD payment.",
            ),
            message: String.nonPluralLocalizedStringWithFormat(
                format,
                OpenCsvUsdAmount.format(amount),
                issuer,
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
            )
        })
        present(alert, animated: true)
    }

    private func send(amount: UInt64, recipient: String, assetId: String) {
        // Past proving, the coins are spent on-chain: the button never
        // re-arms after anchoring (tapping again would spend a second
        // pair of coins) — the states make that visible.
        setSendState(.proving)
        let thread = self.thread
        Task {
            do {
                self.setSendState(.anchoring)
                let delivery = try await OpenCsvPayments.shared.sendPayment(
                    toOwnerHex: recipient,
                    amount: amount,
                    threadUniqueId: thread.uniqueId,
                    assetIdHex: assetId,
                )
                self.setSendState(.sent)
                do {
                    try await OpenCsvDelivery.deliver(delivery)
                } catch {
                    Logger.warn("OpenCSV consignment queued for retry: \(error)")
                }
                self.dismiss(animated: true)
            } catch OpenCsvPaymentsError.consignmentNotReady(let operationId, let state) {
                // Rust has already persisted (and may have submitted) the
                // exact signed transaction. Foreground recovery resumes the
                // same operation; never re-arm the button for a second spend.
                Logger.info("OpenCSV operation \(operationId) queued in \(state)")
                self.setSendState(.sent)
                self.dismiss(animated: true)
            } catch {
                // Failures surfaced here occurred before the durable signed
                // boundary, so retrying the same user intent is safe.
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
