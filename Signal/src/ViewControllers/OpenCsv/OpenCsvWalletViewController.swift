//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreImage
import SignalServiceKit
import SignalUI
import UIKit

/// The wallet screen: everything about the wallet that is not sending.
/// Balance, receiving (key as QR — hex demoted to a copyable detail), and
/// the chain configuration behind an Advanced disclosure. The send sheet
/// deliberately carries none of this: configuration is not sending.
class OpenCsvWalletViewController: OWSViewController {

    /// Present when opened from a conversation, enabling share-in-chat.
    private let thread: TSThread?

    private let stack = UIStackView()
    private let scrollView = UIScrollView()
    private let balanceLabel = UILabel()
    private let qrImageView = UIImageView()
    private let ownerLabel = UILabel()
    private let feeReserveLabel = UILabel()
    private let bitcoinQrImageView = UIImageView()
    private let bitcoinAddressLabel = UILabel()
    private let utxoLabel = UILabel()
    private let operationHistoryLabel = UILabel()
    private let walletPolicyLabel = UILabel()
    private let advancedStack = UIStackView()
    private let esploraField = UITextField()
    private let spvPeersField = UITextField()
    private let networkField = UITextField()
    private var owner: String?
    private var bitcoinDepositAddress: String?
    private var latestExplorerUrl: URL?
    private var mintButton: UIButton?
    private var feeBumpButton: UIButton?
    private var feeBumpCandidates = [OpenCsvAccountOperationSummary]()
    private var writeInProgress = false

    init(thread: TSThread?) {
        self.thread = thread
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = OWSLocalizedString(
            "OPENCSV_WALLET_TITLE",
            comment: "Title of the OpenCSV wallet screen.",
        )
        view.backgroundColor = Theme.backgroundColor

        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
        ])

        // Balance.
        balanceLabel.font = .dynamicTypeTitle1
        balanceLabel.adjustsFontSizeToFitWidth = true
        stack.addArrangedSubview(balanceLabel)

        if thread != nil {
            addHeader(OWSLocalizedString(
                "OPENCSV_WALLET_ACTIONS",
                comment: "Section header for OpenCSV wallet write actions.",
            ))
            mintButton = addButton(
                OWSLocalizedString(
                    "OPENCSV_WALLET_MINT",
                    comment: "Button that issues an OpenCSV asset from inside Signal.",
                ),
                action: #selector(didTapMint),
            )
        }

        // Receive: the QR is the interface; hex is a detail.
        addHeader(OWSLocalizedString(
            "OPENCSV_WALLET_RECEIVE",
            comment: "Section header for receiving payments (this wallet's key).",
        ))
        qrImageView.contentMode = .scaleAspectFit
        qrImageView.layer.magnificationFilter = .nearest
        qrImageView.heightAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(qrImageView)
        ownerLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ownerLabel.numberOfLines = 2
        ownerLabel.lineBreakMode = .byCharWrapping
        ownerLabel.textColor = Theme.secondaryTextAndIconColor
        ownerLabel.isUserInteractionEnabled = true
        ownerLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(didTapCopyKey)),
        )
        stack.addArrangedSubview(ownerLabel)
        if thread != nil {
            addButton(
                OWSLocalizedString(
                    "OPENCSV_SEND_SHARE_KEY_BUTTON",
                    comment: "Button that posts this wallet's receiving key into the chat.",
                ),
                action: #selector(didTapShareKey),
            )
        }

        // Bitcoin is a visible fee reserve, not a general-purpose wallet.
        // Funding is receive-only in Swift; every spend action remains an
        // OpenCSV mint/transfer/fee-bump request enforced by Rust.
        addHeader(OWSLocalizedString(
            "OPENCSV_WALLET_FEE_RESERVE",
            comment: "Section header for the Bitcoin reserve used only for OpenCSV protocol fees.",
        ))
        feeReserveLabel.font = .dynamicTypeBody
        feeReserveLabel.numberOfLines = 0
        stack.addArrangedSubview(feeReserveLabel)
        bitcoinQrImageView.contentMode = .scaleAspectFit
        bitcoinQrImageView.layer.magnificationFilter = .nearest
        bitcoinQrImageView.heightAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(bitcoinQrImageView)
        bitcoinAddressLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        bitcoinAddressLabel.numberOfLines = 0
        bitcoinAddressLabel.lineBreakMode = .byCharWrapping
        bitcoinAddressLabel.textColor = Theme.secondaryTextAndIconColor
        bitcoinAddressLabel.isUserInteractionEnabled = true
        bitcoinAddressLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(didTapCopyBitcoinAddress)),
        )
        stack.addArrangedSubview(bitcoinAddressLabel)
        utxoLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        utxoLabel.numberOfLines = 0
        utxoLabel.textColor = Theme.secondaryTextAndIconColor
        stack.addArrangedSubview(utxoLabel)
        walletPolicyLabel.font = .dynamicTypeCaption1
        walletPolicyLabel.numberOfLines = 0
        walletPolicyLabel.textColor = Theme.secondaryTextAndIconColor
        stack.addArrangedSubview(walletPolicyLabel)
        feeBumpButton = addButton(
            OWSLocalizedString(
                "OPENCSV_WALLET_FEE_BUMP",
                comment: "Button that raises the fee of an unconfirmed OpenCSV transaction.",
            ),
            action: #selector(didTapFeeBump),
        )
        feeBumpButton?.isEnabled = false
        operationHistoryLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        operationHistoryLabel.numberOfLines = 0
        operationHistoryLabel.textColor = Theme.secondaryTextAndIconColor
        stack.addArrangedSubview(operationHistoryLabel)
        let explorerButton = addButton(
            OWSLocalizedString(
                "OPENCSV_WALLET_OPEN_LATEST_TRANSACTION",
                comment: "Button opening the latest OpenCSV Bitcoin fee transaction in a public explorer.",
            ),
            action: #selector(didTapLatestTransaction),
        )
        explorerButton.tag = 7301
        explorerButton.isEnabled = false

        if SUIEnvironment.shared.paymentsRef.paymentsEntropy != nil {
            let warning = UILabel()
            warning.font = .dynamicTypeCaption1
            warning.numberOfLines = 0
            warning.textColor = Theme.secondaryTextAndIconColor
            warning.text = OWSLocalizedString(
                "OPENCSV_LEGACY_MOBILECOIN_WARNING",
                comment: "Read-only warning shown when legacy MobileCoin recovery material remains on the device.",
            )
            stack.addArrangedSubview(warning)
            addButton(
                OWSLocalizedString(
                    "OPENCSV_LEGACY_MOBILECOIN_EXPORT",
                    comment: "Button opening the protected export flow for a legacy MobileCoin recovery phrase.",
                ),
                action: #selector(didTapLegacyMobileCoinExport),
            )
        }

        // Advanced: the chain configuration, collapsed by default. These
        // are the same persisted settings as always; only their address
        // changed.
        addButton(
            OWSLocalizedString(
                "OPENCSV_WALLET_ADVANCED",
                comment: "Disclosure button revealing advanced chain configuration.",
            ),
            action: #selector(didTapAdvanced),
        )
        advancedStack.axis = .vertical
        advancedStack.spacing = 12
        advancedStack.isHidden = true
        for (field, placeholderKey, placeholderComment) in [
            (
                networkField,
                "OPENCSV_SEND_NETWORK_PLACEHOLDER",
                "Placeholder for the Bitcoin network field in the OpenCSV send sheet.",
            ),
            (
                spvPeersField,
                "OPENCSV_SEND_SPV_PEERS_PLACEHOLDER",
                "Placeholder for the Bitcoin P2P peers field in the OpenCSV send sheet.",
            ),
            (
                esploraField,
                "OPENCSV_WALLET_ESPLORA_PLACEHOLDER",
                "Placeholder for the generic Esplora read accelerator in the OpenCSV wallet.",
            ),
        ] {
            field.placeholder = OWSLocalizedString(placeholderKey, comment: placeholderComment)
            field.borderStyle = .roundedRect
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            advancedStack.addArrangedSubview(field)
        }
        esploraField.addTarget(self, action: #selector(esploraChanged), for: .editingDidEnd)
        spvPeersField.addTarget(self, action: #selector(spvPeersChanged), for: .editingDidEnd)
        networkField.addTarget(self, action: #selector(networkChanged), for: .editingDidEnd)
        stack.addArrangedSubview(advancedStack)

        refresh()
    }

    private func refresh() {
        Task {
            do {
                let summary = try await OpenCsvPayments.shared.walletSummary()
                self.owner = summary.owner
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
                self.qrImageView.image = Self.qrImage(for: summary.owner)
                self.bitcoinDepositAddress = summary.bitcoinDepositAddress
                self.bitcoinAddressLabel.text = summary.bitcoinDepositAddress
                self.bitcoinQrImageView.image = Self.qrImage(for: summary.bitcoinDepositAddress)
                self.feeReserveLabel.text = "\(summary.feeReserve.totalSats) sats (\(summary.feeReserve.confirmedSats) confirmed)"
                self.utxoLabel.text = summary.feeReserve.utxos.isEmpty
                    ? "No fee UTXOs"
                    : summary.feeReserve.utxos.map {
                        "\($0.txid.prefix(10)): \($0.vout) · \($0.valueSats) sats\($0.reserved ? " · reserved" : "")"
                    }.joined(separator: "\n")
                self.walletPolicyLabel.text = [
                    "Bitcoin spending: OpenCSV fees only",
                    "Backup: \(summary.backupVerified ? "verified" : "required")",
                    "Device: \(summary.accountRole.rawValue), \(summary.deviceBindingStatus)",
                    "Spend state: \(summary.syncProvenance.authoritative)",
                ].joined(separator: "\n")
                self.feeBumpCandidates = summary.operations.filter {
                    ["broadcast_unobserved", "broadcast", "mempool"].contains($0.state)
                }
                self.operationHistoryLabel.text = summary.operations.isEmpty
                    ? "No OpenCSV Bitcoin transactions"
                    : summary.operations.suffix(8).reversed().map {
                        let txid = $0.txid.map { String($0.prefix(10)) } ?? "unsigned"
                        return "\($0.kind) · \($0.state) · \(txid)"
                    }.joined(separator: "\n")
                let latestTxid = summary.operations.reversed().compactMap(\.txid).first
                self.latestExplorerUrl = latestTxid.flatMap { txid in
                    switch summary.network {
                    case "mainnet": URL(string: "https://mempool.space/tx/\(txid)")
                    case "signet": URL(string: "https://mempool.space/signet/tx/\(txid)")
                    default: nil
                    }
                }
                self.stack.viewWithTag(7301)?.isUserInteractionEnabled = self.latestExplorerUrl != nil
                (self.stack.viewWithTag(7301) as? UIButton)?.isEnabled = self.latestExplorerUrl != nil
                self.mintButton?.isEnabled = summary.writeEnabled && !self.writeInProgress
                self.feeBumpButton?.isEnabled = summary.writeEnabled
                    && !self.writeInProgress
                    && !self.feeBumpCandidates.isEmpty
                self.esploraField.text = summary.esploraUrl?.absoluteString
                self.spvPeersField.text = summary.spvPeers.joined(separator: ", ")
                self.networkField.text = summary.network
            } catch {
                self.balanceLabel.text = "\(error)"
            }
        }
    }

    private static func qrImage(for text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return UIImage(ciImage: scaled)
    }

    // MARK: - Actions

    @objc
    private func didTapCopyKey() {
        UIPasteboard.general.string = owner
        presentToast(text: OWSLocalizedString(
            "OPENCSV_SEND_KEY_COPIED",
            comment: "Confirmation that the wallet's receiving key was copied.",
        ))
    }

    @objc
    private func didTapShareKey() {
        guard let owner, let thread else { return }
        ThreadUtil.enqueueMessage(
            body: MessageBody(
                text: OpenCsvAttachmentDetector.addressAnnouncement(owner: owner),
                ranges: .empty,
            ),
            thread: thread,
        )
        presentToast(text: OWSLocalizedString(
            "OPENCSV_SEND_KEY_SHARED",
            comment: "Confirmation that the wallet's receiving key was posted to the chat.",
        ))
    }

    @objc
    private func didTapCopyBitcoinAddress() {
        UIPasteboard.general.string = bitcoinDepositAddress
        presentToast(text: OWSLocalizedString(
            "OPENCSV_WALLET_FEE_ADDRESS_COPIED",
            comment: "Confirmation that the Bitcoin fee-reserve deposit address was copied.",
        ))
    }

    @objc
    private func didTapLatestTransaction() {
        guard let latestExplorerUrl else { return }
        UIApplication.shared.open(latestExplorerUrl)
    }

    @objc
    private func didTapAdvanced() {
        advancedStack.isHidden.toggle()
    }

    @objc
    private func didTapMint() {
        guard let thread else { return }
        let alert = UIAlertController(
            title: OWSLocalizedString(
                "OPENCSV_WALLET_MINT",
                comment: "Title of the OpenCSV asset issuance form.",
            ),
            message: OWSLocalizedString(
                "OPENCSV_WALLET_MINT_EXPLANATION",
                comment: "Explanation that minting issues an asset and spends Bitcoin only for its protocol fee.",
            ),
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "USD"
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "100"
            field.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: CommonStrings.cancelButton, style: .cancel))
        alert.addAction(UIAlertAction(
            title: OWSLocalizedString(
                "OPENCSV_WALLET_MINT_CONFIRM",
                comment: "Confirmation button for issuing an OpenCSV asset.",
            ),
            style: .default,
        ) { [weak self, weak alert] _ in
            guard
                let self,
                let currency = alert?.textFields?.first?.text?.strippedOrNil,
                let amountText = alert?.textFields?.last?.text,
                let amount = UInt64(amountText),
                amount > 0
            else { return }
            self.performWalletWrite {
                let delivery = try await OpenCsvPayments.shared.mintAsset(
                    currency: currency,
                    amount: amount,
                    threadUniqueId: thread.uniqueId,
                )
                try await OpenCsvDelivery.deliver(delivery)
            }
        })
        present(alert, animated: true)
    }

    @objc
    private func didTapFeeBump() {
        guard !feeBumpCandidates.isEmpty else { return }
        if feeBumpCandidates.count == 1, let operation = feeBumpCandidates.first {
            promptForFeeRate(operation: operation)
            return
        }
        let sheet = ActionSheetController(
            title: OWSLocalizedString(
                "OPENCSV_WALLET_FEE_BUMP",
                comment: "Title for selecting an OpenCSV transaction to fee-bump.",
            ),
            message: nil,
        )
        for operation in feeBumpCandidates {
            let title = "\(operation.kind.capitalized) · \(operation.operationId.prefix(10))"
            sheet.addAction(ActionSheetAction(title: title, style: .default) { [weak self] _ in
                self?.promptForFeeRate(operation: operation)
            })
        }
        sheet.addAction(ActionSheetAction(title: CommonStrings.cancelButton, style: .cancel))
        presentActionSheet(sheet)
    }

    private func promptForFeeRate(operation: OpenCsvAccountOperationSummary) {
        let alert = UIAlertController(
            title: OWSLocalizedString(
                "OPENCSV_WALLET_FEE_RATE",
                comment: "Title asking for a target Bitcoin fee rate.",
            ),
            message: "Operation \(operation.operationId.prefix(12))",
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "5 sat/vB"
            field.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: CommonStrings.cancelButton, style: .cancel))
        alert.addAction(UIAlertAction(title: CommonStrings.okButton, style: .default) { [weak self, weak alert] _ in
            guard
                let self,
                let text = alert?.textFields?.first?.text,
                let target = UInt64(text),
                target > 0
            else { return }
            self.performWalletWrite {
                _ = try await OpenCsvPayments.shared.feeBump(
                    operationId: operation.operationId,
                    targetSatPerVb: target,
                )
            }
        })
        present(alert, animated: true)
    }

    private func performWalletWrite(_ operation: @escaping () async throws -> Void) {
        guard !writeInProgress else { return }
        writeInProgress = true
        mintButton?.isEnabled = false
        feeBumpButton?.isEnabled = false
        Task {
            defer {
                self.writeInProgress = false
                self.refresh()
            }
            do {
                try await operation()
                self.presentToast(text: OWSLocalizedString(
                    "OPENCSV_WALLET_OPERATION_COMMITTED",
                    comment: "Confirmation that an OpenCSV wallet operation was committed.",
                ))
            } catch OpenCsvPaymentsError.consignmentNotReady(let operationId, let state) {
                self.presentToast(text: "OpenCSV \(operationId.prefix(10)) is durable and awaiting \(state).")
            } catch OpenCsvPaymentsError.feeBumpCommittedBackupPending(let operationId, _) {
                self.presentError("Fee bump \(operationId.prefix(10)) was committed; Secure Backup refresh is still required.")
            } catch {
                self.presentError("\(error)")
            }
        }
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: CommonStrings.errorAlertTitle, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: CommonStrings.okButton, style: .default))
        present(alert, animated: true)
    }

    @objc
    private func didTapLegacyMobileCoinExport() {
        guard let passphrase = SUIEnvironment.shared.paymentsSwiftRef.passphrase else {
            presentError("Legacy MobileCoin recovery material could not be decoded.")
            return
        }
        let view = PaymentsViewPassphraseSplashViewController(
            passphrase: passphrase,
            style: .reviewed,
            viewPassphraseDelegate: self,
        )
        present(OWSNavigationController(rootViewController: view), animated: true)
    }

    @objc
    private func esploraChanged() {
        let url = esploraField.text?.strippedOrNil
        Task { await OpenCsvPayments.shared.setEsploraUrl(url) }
    }

    @objc
    private func spvPeersChanged() {
        let peers = (spvPeersField.text ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        Task { await OpenCsvPayments.shared.setSpvPeers(peers) }
    }

    @objc
    private func networkChanged() {
        let network = networkField.text?.strippedOrNil ?? "signet"
        Task { await OpenCsvPayments.shared.setNetwork(network) }
    }

    // MARK: - Helpers

    private func addHeader(_ text: String) {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .dynamicTypeCaption1
        label.textColor = Theme.secondaryTextAndIconColor
        stack.setCustomSpacing(24, after: stack.arrangedSubviews.last ?? label)
        stack.addArrangedSubview(label)
    }

    @discardableResult
    private func addButton(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .dynamicTypeBody
        button.addTarget(self, action: action, for: .touchUpInside)
        stack.addArrangedSubview(button)
        return button
    }
}

extension OpenCsvWalletViewController: PaymentsViewPassphraseDelegate {
    func viewPassphraseDidCancel(viewController: PaymentsViewPassphraseSplashViewController) {
        viewPassphraseDidComplete()
    }

    func viewPassphraseDidComplete() {
        dismiss(animated: true)
    }
}
