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
    private var feeBumpButton: UIButton?
    private var feeReserveDetailsButton: UIButton?
    private var advancedButton: UIButton?
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
        // OpenCSV transfer/fee-bump request enforced by Rust.
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
        let trustedUsd = instruments.filter {
            $0.profile == "trusted_usd_v1"
                && $0.trustState == "trusted_configuration"
                && $0.manifest?.terms.unitCode == "USD"
                && $0.manifest?.terms.decimals == 6
        }.sorted {
            let left = ($0.issuerPriority ?? UInt32.max, $0.assetId)
            let right = ($1.issuerPriority ?? UInt32.max, $1.assetId)
            return left < right
        }
        let trustedIds = Set(trustedUsd.map(\.assetId))
        let trustedBalances = balances.filter { trustedIds.contains($0.assetId) }
        let total = trustedBalances.reduce(UInt64(0)) { partial, balance in
            let (combined, overflow) = partial.addingReportingOverflow(balance.amount)
            return overflow ? UInt64.max : combined
        }
        var sections = [[
            "USD",
            "\(OpenCsvUsdAmount.format(total)) USD",
            OWSLocalizedString(
                "OPENCSV_WALLET_USD_DISCLOSURE",
                comment: "Disclosure that one USD product can contain exact issuer-specific claims.",
            ),
            trustedUsd.isEmpty
                ? OWSLocalizedString(
                    "OPENCSV_WALLET_NO_TRUSTED_USD_ISSUERS",
                    comment: "State shown when no reviewed USD issuer manifests are configured.",
                )
                : String.nonPluralLocalizedStringWithFormat(
                    OWSLocalizedString(
                        "OPENCSV_WALLET_USD_ISSUER_COUNT_FORMAT",
                        comment: "Count of configured issuer instruments under USD.",
                    ),
                    "\(trustedUsd.count)",
                ),
        ].joined(separator: "\n")]

        sections += trustedUsd.map { instrument in
            let manifest = instrument.manifest!
            let balance = trustedBalances.first { $0.assetId == instrument.assetId }?.amount ?? 0
            let shortId = "\(instrument.assetId.prefix(12).lowercased())…\(instrument.assetId.suffix(6).lowercased())"
            let backing = manifest.terms.testOnly
                ? OWSLocalizedString(
                    "OPENCSV_WALLET_TEST_INSTRUMENT",
                    comment: "Warning label for a test-only instrument.",
                )
                : manifest.terms.redemptionSummary
            return [
                manifest.terms.issuerName,
                "\(OpenCsvUsdAmount.format(balance)) USD",
                "\(manifest.terms.displayName) · \(backing)",
                shortId,
            ].joined(separator: "\n")
        }

        sections += balances.compactMap { balance in
            if trustedIds.contains(balance.assetId) { return nil }
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
                    "OPENCSV_WALLET_UNTRUSTED_INSTRUMENT",
                    comment: "Title for a manifested instrument outside the reviewed issuer configuration.",
                ),
                "\(displayAmount(balance.amount, decimals: manifest.terms.decimals)) \(manifest.terms.unitCode)",
                "\(manifest.terms.issuerName) · read only",
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
