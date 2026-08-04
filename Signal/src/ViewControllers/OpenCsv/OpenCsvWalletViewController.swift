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
    private let feeReserveExplanationLabel = UILabel()
    private let feeReserveDetailsStack = UIStackView()
    private let advancedStack = UIStackView()
    private let esploraField = UITextField()
    private let spvPeersField = UITextField()
    private let networkField = UITextField()
    private var owner: String?
    private var bitcoinDepositAddress: String?
    private var latestExplorerUrl: URL?
    private var usdIssuerButton: UIButton?
    private var feeBumpButton: UIButton?
    private var feeReserveDetailsButton: UIButton?
    private var advancedButton: UIButton?
    private var feeBumpCandidates = [OpenCsvAccountOperationSummary]()
    private var usdPreviewInstrument: OpenCsvInstrumentRecord?
    private var walletNetwork = "signet"
    private var accountRole = OpenCsvAccountRole.primary
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

        advancedStack.axis = .vertical
        advancedStack.spacing = 12
        advancedStack.isHidden = true

        // Holdings are exact issuer-backed instruments. A display code is
        // never treated as identity and prototype assets remain explicit.
        addHeader(OWSLocalizedString(
            "OPENCSV_WALLET_ASSETS",
            comment: "Section header for the assets held by the OpenCSV wallet.",
        ))
        balanceLabel.font = .dynamicTypeBody
        balanceLabel.numberOfLines = 0
        stack.addArrangedSubview(balanceLabel)

        // Receive: the QR is the interface; hex is a detail.
        addHeader(OWSLocalizedString(
            "OPENCSV_WALLET_RECEIVE",
            comment: "Section header for receiving payments (this wallet's key).",
        ))
        qrImageView.contentMode = .scaleAspectFit
        qrImageView.layer.magnificationFilter = .nearest
        qrImageView.heightAnchor.constraint(equalToConstant: 160).isActive = true
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
        feeReserveExplanationLabel.font = .dynamicTypeFootnote
        feeReserveExplanationLabel.numberOfLines = 0
        feeReserveExplanationLabel.textColor = Theme.secondaryTextAndIconColor
        feeReserveExplanationLabel.text = OWSLocalizedString(
            "OPENCSV_WALLET_FEE_RESERVE_EXPLANATION",
            comment: "Explanation of the restricted Bitcoin fee reserve.",
        )
        stack.addArrangedSubview(feeReserveExplanationLabel)
        feeReserveDetailsButton = addButton(
            OWSLocalizedString(
                "OPENCSV_WALLET_SHOW_FUNDING_ADDRESS",
                comment: "Button that reveals the Bitcoin fee-reserve funding address.",
            ),
            action: #selector(didTapFeeReserveDetails),
        )
        feeReserveDetailsStack.axis = .vertical
        feeReserveDetailsStack.spacing = 12
        feeReserveDetailsStack.isHidden = true
        bitcoinQrImageView.contentMode = .scaleAspectFit
        bitcoinQrImageView.layer.magnificationFilter = .nearest
        bitcoinQrImageView.heightAnchor.constraint(equalToConstant: 160).isActive = true
        feeReserveDetailsStack.addArrangedSubview(bitcoinQrImageView)
        bitcoinAddressLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        bitcoinAddressLabel.numberOfLines = 0
        bitcoinAddressLabel.lineBreakMode = .byCharWrapping
        bitcoinAddressLabel.textColor = Theme.secondaryTextAndIconColor
        bitcoinAddressLabel.isUserInteractionEnabled = true
        bitcoinAddressLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(didTapCopyBitcoinAddress)),
        )
        feeReserveDetailsStack.addArrangedSubview(bitcoinAddressLabel)
        stack.addArrangedSubview(feeReserveDetailsStack)
        utxoLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        utxoLabel.numberOfLines = 0
        utxoLabel.textColor = Theme.secondaryTextAndIconColor
        advancedStack.addArrangedSubview(utxoLabel)
        walletPolicyLabel.font = .dynamicTypeCaption1
        walletPolicyLabel.numberOfLines = 0
        walletPolicyLabel.textColor = Theme.secondaryTextAndIconColor
        advancedStack.addArrangedSubview(walletPolicyLabel)
        usdIssuerButton = addButton(
            OWSLocalizedString(
                "OPENCSV_WALLET_ISSUER_TOOLS",
                comment: "Button opening the fixed USD preview issuer control.",
            ),
            action: #selector(didTapUsdIssuer),
            to: advancedStack,
        )

        addHeader(OWSLocalizedString(
            "OPENCSV_WALLET_ACTIVITY",
            comment: "Section header for OpenCSV wallet operation history.",
        ))
        operationHistoryLabel.font = .dynamicTypeFootnote
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
        feeBumpButton = addButton(
            OWSLocalizedString(
                "OPENCSV_WALLET_FEE_BUMP",
                comment: "Button that raises the fee of an unconfirmed OpenCSV transaction.",
            ),
            action: #selector(didTapFeeBump),
        )
        feeBumpButton?.isEnabled = false

        if SUIEnvironment.shared.paymentsRef.paymentsEntropy != nil {
            addHeader(OWSLocalizedString(
                "OPENCSV_LEGACY_MOBILECOIN_TITLE",
                comment: "Section header for legacy MobileCoin recovery material.",
            ))
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
        advancedButton = addButton(
            OWSLocalizedString(
                "OPENCSV_WALLET_ADVANCED",
                comment: "Disclosure button revealing advanced chain configuration.",
            ),
            action: #selector(didTapAdvanced),
        )
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
                // Status is cache-backed. Refresh it before rendering so a
                // newly funded or newly confirmed output becomes visible
                // without relying on a write attempt.
                _ = try? await OpenCsvPayments.shared.syncAccount()
                let summary = try await OpenCsvPayments.shared.walletSummary()
                self.owner = summary.owner
                self.usdPreviewInstrument = summary.instruments.first {
                    $0.profile == "usd_preview_v1"
                }
                self.walletNetwork = summary.network
                self.accountRole = summary.accountRole
                self.balanceLabel.text = Self.renderHoldings(
                    summary.balances,
                    instruments: summary.instruments,
                )
                self.ownerLabel.text = String.nonPluralLocalizedStringWithFormat(
                    OWSLocalizedString(
                        "OPENCSV_WALLET_RECEIVE_KEY_FORMAT",
                        comment: "Abbreviated OpenCSV receiving key. Embeds {{ key prefix }} and {{ key suffix }}.",
                    ),
                    String(summary.owner.prefix(12)).lowercased(),
                    String(summary.owner.suffix(8)).lowercased(),
                )
                self.qrImageView.image = Self.qrImage(for: summary.owner)
                self.bitcoinDepositAddress = summary.bitcoinDepositAddress
                self.bitcoinAddressLabel.text = summary.bitcoinDepositAddress
                self.bitcoinQrImageView.image = Self.qrImage(for: summary.bitcoinDepositAddress)
                self.feeReserveLabel.text = String.nonPluralLocalizedStringWithFormat(
                    OWSLocalizedString(
                        "OPENCSV_WALLET_FEE_RESERVE_FORMAT",
                        comment: "Bitcoin fee reserve summary. Embeds {{ total sats }} and {{ confirmed sats }}.",
                    ),
                    "\(summary.feeReserve.totalSats)",
                    "\(summary.feeReserve.confirmedSats)",
                )
                self.utxoLabel.text = summary.feeReserve.utxos.isEmpty
                    ? OWSLocalizedString(
                        "OPENCSV_WALLET_NO_FEE_UTXOS",
                        comment: "Shown in advanced wallet details when there are no Bitcoin fee UTXOs.",
                    )
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
                    ? OWSLocalizedString(
                        "OPENCSV_WALLET_NO_ACTIVITY",
                        comment: "Shown when there are no OpenCSV wallet operations yet.",
                    )
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
                self.stack.viewWithTag(7301)?.isHidden = self.latestExplorerUrl == nil
                self.usdIssuerButton?.isEnabled = summary.accountRole == .primary
                    && !self.writeInProgress
                self.feeBumpButton?.isHidden = self.feeBumpCandidates.isEmpty
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

    private static func renderHoldings(
        _ balances: [OpenCsvCredit],
        instruments: [OpenCsvInstrumentRecord],
    ) -> String {
        let records = Dictionary(uniqueKeysWithValues: instruments.map { ($0.assetId, $0) })
        let preview = instruments.first { $0.profile == "usd_preview_v1" }
        let previewBalance = preview.flatMap { instrument in
            balances.first { $0.assetId == instrument.assetId }
        }?.amount ?? 0
        var sections = [[
            "OpenCSV USD Preview",
            "\(displayAmount(previewBalance, decimals: 6)) USD",
            OWSLocalizedString(
                "OPENCSV_WALLET_USD_PREVIEW_DISCLOSURE",
                comment: "Disclosure that USD Preview is a valueless signet test and not USDT.",
            ),
            preview.map { "\($0.assetId.prefix(12).lowercased())…\($0.assetId.suffix(6).lowercased())" }
                ?? OWSLocalizedString(
                    "OPENCSV_WALLET_USD_PREVIEW_NOT_ACTIVATED",
                    comment: "State shown before the USD preview issuer definition exists.",
                ),
        ].joined(separator: "\n")]

        sections += balances.compactMap { balance in
            if balance.assetId == preview?.assetId { return nil }
            let shortId = "\(balance.assetId.prefix(12).lowercased())…\(balance.assetId.suffix(6).lowercased())"
            guard let record = records[balance.assetId], let manifest = record.manifest else {
                let oldLabel = balance.currency.map { " · legacy label \($0)" } ?? ""
                return [
                    OWSLocalizedString(
                        "OPENCSV_WALLET_PROTOTYPE_ASSET",
                        comment: "Title for a legacy asset with no committed instrument manifest.",
                    ),
                    "\(balance.amount) base units\(oldLabel)",
                    shortId,
                ].joined(separator: "\n")
            }
            return [
                OWSLocalizedString(
                    "OPENCSV_WALLET_UNSUPPORTED_INSTRUMENT",
                    comment: "Title for a manifested custom instrument no longer supported by the preview wallet.",
                ),
                "\(displayAmount(balance.amount, decimals: manifest.terms.decimals)) \(manifest.terms.unitCode)",
                "\(manifest.terms.displayName) · read only",
                shortId,
            ].joined(separator: "\n")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func displayAmount(_ baseUnits: UInt64, decimals: UInt8) -> String {
        guard decimals > 0 else { return "\(baseUnits)" }
        let divisor = (0..<decimals).reduce(UInt64(1)) { value, _ in value * 10 }
        guard divisor > 1 else { return "\(baseUnits)" }
        let whole = baseUnits / divisor
        let fraction = String(format: "%0*llu", Int(decimals), baseUnits % divisor)
        return "\(whole).\(fraction)"
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
    private func didTapFeeReserveDetails() {
        feeReserveDetailsStack.isHidden.toggle()
        let key = feeReserveDetailsStack.isHidden
            ? "OPENCSV_WALLET_SHOW_FUNDING_ADDRESS"
            : "OPENCSV_WALLET_HIDE_FUNDING_ADDRESS"
        feeReserveDetailsButton?.setTitle(
            OWSLocalizedString(key, comment: "Button that toggles the Bitcoin fee-reserve funding address."),
            for: .normal,
        )
    }

    @objc
    private func didTapAdvanced() {
        advancedStack.isHidden.toggle()
        let key = advancedStack.isHidden
            ? "OPENCSV_WALLET_ADVANCED"
            : "OPENCSV_WALLET_HIDE_ADVANCED"
        advancedButton?.setTitle(
            OWSLocalizedString(key, comment: "Button that toggles advanced OpenCSV wallet settings."),
            for: .normal,
        )
    }

    @objc
    private func didTapUsdIssuer() {
        guard accountRole == .primary else { return }
        let controller = OpenCsvUsdIssuerViewController(
            thread: thread,
            network: walletNetwork,
            instrument: usdPreviewInstrument,
        ) { [weak self] in
            self?.refresh()
        }
        navigationController?.pushViewController(controller, animated: true)
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
        usdIssuerButton?.isEnabled = false
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
            } catch OpenCsvPaymentsError.feeReserveRequired {
                self.revealFeeReserveAndPresentRequirement()
            } catch {
                self.presentError("\(error)")
            }
        }
    }

    private func revealFeeReserveAndPresentRequirement() {
        if feeReserveDetailsStack.isHidden {
            didTapFeeReserveDetails()
        }
        let format = OWSLocalizedString(
            "OPENCSV_WALLET_FEE_RESERVE_REQUIRED_FORMAT",
            comment: "Error shown when the Bitcoin fee reserve cannot yet fund an OpenCSV operation. Embeds {{ minimum sats }}.",
        )
        presentError(String.nonPluralLocalizedStringWithFormat(
            format,
            "\(OpenCsvPayments.minimumFeeReserveSats)",
        ))
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
        Task {
            do {
                try await OpenCsvPayments.shared.setNetwork(network)
                self.refresh()
            } catch OpenCsvPaymentsError.networkChangeRequiresIsolatedWallet(let current, let requested) {
                self.networkField.text = current
                self.presentError(
                    "This wallet is bound to \(current). Use a clean isolated installation to test \(requested); existing wallet and CBF cache data were not changed.",
                )
            } catch OpenCsvPaymentsError.unsupportedNetwork(let requested) {
                self.refresh()
                self.presentError("Unsupported Bitcoin network: \(requested).")
            } catch {
                self.refresh()
                self.presentError("\(error)")
            }
        }
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
    private func addButton(_ title: String, action: Selector, to parent: UIStackView? = nil) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .dynamicTypeBody
        button.addTarget(self, action: action, for: .touchUpInside)
        (parent ?? stack).addArrangedSubview(button)
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

/// The one issuer action exposed by the preview wallet. Product metadata is
/// fixed in Rust; this screen accepts only a human USD amount.
private final class OpenCsvUsdIssuerViewController: OWSViewController {
    private let thread: TSThread?
    private let network: String
    private let instrument: OpenCsvInstrumentRecord?
    private let onChange: () -> Void
    private let stack = UIStackView()
    private var operationInProgress = false

    init(
        thread: TSThread?,
        network: String,
        instrument: OpenCsvInstrumentRecord?,
        onChange: @escaping () -> Void,
    ) {
        self.thread = thread
        self.network = network
        self.instrument = instrument
        self.onChange = onChange
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = OWSLocalizedString(
            "OPENCSV_ISSUER_TOOLS_TITLE",
            comment: "Title of the advanced OpenCSV issuer tools screen.",
        )
        view.backgroundColor = Theme.backgroundColor

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
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

        addText(OWSLocalizedString(
            "OPENCSV_ISSUER_TOOLS_EXPLANATION",
            comment: "Explanation of the fixed, test-only USD preview issuer action.",
        ), color: Theme.secondaryTextAndIconColor)
        addHeader(OWSLocalizedString(
            "OPENCSV_ISSUER_INSTRUMENTS",
            comment: "Section title for the fixed USD preview instrument.",
        ))
        addText("OpenCSV USD Preview\nUSD · 6 decimals\nOpenCSV Preview Issuer", color: Theme.primaryTextColor)
        if let instrument {
            addText("Asset ID\n\(instrument.assetId)", color: Theme.secondaryTextAndIconColor)
        } else {
            addText(OWSLocalizedString(
                "OPENCSV_WALLET_USD_PREVIEW_NOT_ACTIVATED",
                comment: "State shown before the USD preview issuer definition exists.",
            ), color: Theme.secondaryTextAndIconColor)
        }

        let terms = addButton(OWSLocalizedString(
            "OPENCSV_ISSUER_OPEN_TERMS",
            comment: "Button opening the fixed USD preview terms document.",
        ))
        terms.addTarget(self, action: #selector(didTapTerms), for: .touchUpInside)

        let issue = addButton(OWSLocalizedString(
            "OPENCSV_ISSUER_ISSUE_UNITS",
            comment: "Button issuing the fixed test-only USD preview instrument.",
        ))
        issue.addTarget(self, action: #selector(didTapIssue), for: .touchUpInside)
        issue.isEnabled = network != "mainnet" && thread != nil
        if network == "mainnet" {
            addText(
                OWSLocalizedString(
                    "OPENCSV_ISSUER_MAINNET_DISABLED",
                    comment: "Warning that USD Preview issuance is unavailable on mainnet.",
                ),
                color: Theme.secondaryTextAndIconColor,
            )
        } else if thread == nil {
            addText(OWSLocalizedString(
                "OPENCSV_ISSUER_CONVERSATION_REQUIRED",
                comment: "Instruction to open USD issuance from a Signal conversation.",
            ), color: Theme.secondaryTextAndIconColor)
        }
    }

    @objc
    private func didTapTerms() {
        let rawUrl = instrument?.manifest?.terms.termsUri
            ?? "https://opencsv.net/usd-preview/terms-v1"
        guard let url = URL(string: rawUrl) else { return }
        UIApplication.shared.open(url)
    }

    @objc
    private func didTapIssue() {
        promptForIssuance()
    }

    private func promptForIssuance() {
        guard let thread, network != "mainnet" else { return }
        let alert = UIAlertController(
            title: OWSLocalizedString(
                "OPENCSV_ISSUER_ISSUE_UNITS",
                comment: "Title of the USD preview issuance amount prompt.",
            ),
            message: OWSLocalizedString(
                "OPENCSV_ISSUER_USD_PREVIEW_WARNING",
                comment: "Warning shown before issuing test-only USD preview units.",
            ),
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = OWSLocalizedString(
                "OPENCSV_ISSUER_BASE_UNITS_PLACEHOLDER",
                comment: "Placeholder for a human USD preview amount.",
            )
            field.keyboardType = .decimalPad
        }
        alert.addAction(UIAlertAction(title: CommonStrings.cancelButton, style: .cancel))
        alert.addAction(UIAlertAction(
            title: OWSLocalizedString(
                "OPENCSV_ISSUER_REVIEW_ISSUANCE",
                comment: "Button confirming an exact instrument issuance.",
            ),
            style: .default,
        ) { [weak self, weak alert] _ in
            guard
                let self,
                let value = alert?.textFields?.first?.text,
                let amount = OpenCsvUsdPreviewAmount.parse(value),
                amount > 0,
                !self.operationInProgress
            else { return }
            self.operationInProgress = true
            Task {
                defer { self.operationInProgress = false }
                do {
                    let delivery = try await OpenCsvPayments.shared.issuePreviewUsd(
                        amount: amount,
                        threadUniqueId: thread.uniqueId,
                    )
                    try await OpenCsvDelivery.deliver(delivery)
                    self.onChange()
                    self.presentToast(text: OWSLocalizedString(
                        "OPENCSV_ISSUER_ISSUANCE_COMMITTED",
                        comment: "Confirmation after instrument units are issued and delivery is queued.",
                    ))
                } catch {
                    self.showError("\(error)")
                }
            }
        })
        present(alert, animated: true)
    }

    private func addHeader(_ text: String) {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .dynamicTypeCaption1
        label.textColor = Theme.secondaryTextAndIconColor
        stack.addArrangedSubview(label)
    }

    private func addText(_ text: String, color: UIColor) {
        let label = UILabel()
        label.text = text
        label.font = .dynamicTypeBody
        label.textColor = color
        label.numberOfLines = 0
        stack.addArrangedSubview(label)
    }

    @discardableResult
    private func addButton(_ title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .dynamicTypeBody
        stack.addArrangedSubview(button)
        return button
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: CommonStrings.errorAlertTitle, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: CommonStrings.okButton, style: .default))
        present(alert, animated: true)
    }
}
