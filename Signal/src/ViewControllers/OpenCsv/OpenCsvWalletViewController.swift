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
    private let balanceStatusLabel = UILabel()
    private let receiveDetailsStack = UIStackView()
    private let qrImageView = UIImageView()
    private let ownerLabel = UILabel()
    private let feeReserveLabel = UILabel()
    private let bitcoinQrImageView = UIImageView()
    private let bitcoinAddressLabel = UILabel()
    private let utxoLabel = UILabel()
    private let operationHistoryLabel = UILabel()
    private let instrumentDetailsLabel = UILabel()
    private let walletPolicyLabel = UILabel()
    private let feeReserveExplanationLabel = UILabel()
    private let feeReserveDetailsStack = UIStackView()
    private let advancedStack = UIStackView()
    private let esploraField = UITextField()
    private let spvPeersField = UITextField()
    private let scanFromHeightField = UITextField()
    private let networkField = UITextField()
    private var owner: String?
    private var bitcoinDepositAddress: String?
    private var latestExplorerUrl: URL?
    private var feeBumpButton: UIButton?
    private var receiveButton: UIButton?
    private var feeReserveDetailsButton: UIButton?
    private var advancedButton: UIButton?
    private var feeBumpCandidates = [OpenCsvAccountOperationSummary]()
    private var writeInProgress = false

    private enum RefreshState: Equatable {
        case updating
        case current
        case failed
    }

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
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
        ])

        advancedStack.axis = .vertical
        advancedStack.spacing = 12
        advancedStack.isHidden = true

        // The first screen is intentionally a consumer wallet, not a protocol
        // inspector. Exact issuer instruments remain visible under Wallet
        // details, but the primary hierarchy is one USD balance and two tasks.
        let balanceCard = UIView()
        balanceCard.backgroundColor = Theme.secondaryBackgroundColor
        balanceCard.layer.cornerRadius = 20
        balanceCard.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 24,
            leading: 20,
            bottom: 24,
            trailing: 20,
        )
        let balanceStack = UIStackView()
        balanceStack.axis = .vertical
        balanceStack.alignment = .center
        balanceStack.spacing = 6
        balanceStack.translatesAutoresizingMaskIntoConstraints = false
        balanceCard.addSubview(balanceStack)
        NSLayoutConstraint.activate([
            balanceStack.topAnchor.constraint(equalTo: balanceCard.layoutMarginsGuide.topAnchor),
            balanceStack.leadingAnchor.constraint(equalTo: balanceCard.layoutMarginsGuide.leadingAnchor),
            balanceStack.trailingAnchor.constraint(equalTo: balanceCard.layoutMarginsGuide.trailingAnchor),
            balanceStack.bottomAnchor.constraint(equalTo: balanceCard.layoutMarginsGuide.bottomAnchor),
        ])
        let currencyLabel = UILabel()
        currencyLabel.text = "USD"
        currencyLabel.font = .dynamicTypeFootnote
        currencyLabel.textColor = Theme.secondaryTextAndIconColor
        balanceStack.addArrangedSubview(currencyLabel)
        balanceLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
            for: UIFont.systemFont(ofSize: 44, weight: .semibold),
        )
        balanceLabel.numberOfLines = 0
        balanceLabel.adjustsFontForContentSizeCategory = true
        balanceLabel.textAlignment = .center
        balanceLabel.text = "—"
        balanceStack.addArrangedSubview(balanceLabel)
        balanceStatusLabel.font = .dynamicTypeFootnote
        balanceStatusLabel.numberOfLines = 0
        balanceStatusLabel.textAlignment = .center
        balanceStatusLabel.textColor = Theme.secondaryTextAndIconColor
        balanceStatusLabel.text = OWSLocalizedString(
            "OPENCSV_WALLET_CHECKING",
            comment: "Status shown while the OpenCSV wallet is loading.",
        )
        balanceStack.addArrangedSubview(balanceStatusLabel)
        stack.addArrangedSubview(balanceCard)

        let actionsStack = UIStackView()
        actionsStack.axis = .horizontal
        actionsStack.distribution = .fillEqually
        actionsStack.spacing = 12
        receiveButton = makeActionButton(
            title: OWSLocalizedString(
                "OPENCSV_WALLET_RECEIVE",
                comment: "Action for revealing the OpenCSV receiving code.",
            ),
            subtitle: "USD",
            imageName: "qrcode",
            action: #selector(didTapReceive),
        )
        actionsStack.addArrangedSubview(receiveButton!)
        feeReserveDetailsButton = makeActionButton(
            title: OWSLocalizedString(
                "OPENCSV_WALLET_NETWORK_FEES",
                comment: "Action for viewing and funding the Bitcoin fee reserve.",
            ),
            subtitle: nil,
            imageName: "bolt.fill",
            action: #selector(didTapFeeReserveDetails),
        )
        actionsStack.addArrangedSubview(feeReserveDetailsButton!)
        stack.addArrangedSubview(actionsStack)

        // Receive details stay collapsed until the user chooses Receive.
        receiveDetailsStack.axis = .vertical
        receiveDetailsStack.alignment = .center
        receiveDetailsStack.spacing = 12
        receiveDetailsStack.isHidden = true
        addHeader(
            OWSLocalizedString(
                "OPENCSV_WALLET_RECEIVE_USD",
                comment: "Heading above the OpenCSV receiving QR code.",
            ),
            to: receiveDetailsStack,
        )
        qrImageView.contentMode = .scaleAspectFit
        qrImageView.layer.magnificationFilter = .nearest
        qrImageView.heightAnchor.constraint(equalToConstant: 160).isActive = true
        qrImageView.widthAnchor.constraint(equalTo: qrImageView.heightAnchor).isActive = true
        receiveDetailsStack.addArrangedSubview(qrImageView)
        ownerLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ownerLabel.numberOfLines = 2
        ownerLabel.lineBreakMode = .byCharWrapping
        ownerLabel.textColor = Theme.secondaryTextAndIconColor
        ownerLabel.isUserInteractionEnabled = true
        ownerLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(didTapCopyKey)),
        )
        receiveDetailsStack.addArrangedSubview(ownerLabel)
        if thread != nil {
            addButton(
                OWSLocalizedString(
                    "OPENCSV_SEND_SHARE_KEY_BUTTON",
                    comment: "Button that posts this wallet's receiving key into the chat.",
                ),
                action: #selector(didTapShareKey),
                to: receiveDetailsStack,
            )
        }
        stack.addArrangedSubview(receiveDetailsStack)

        // Bitcoin stays policy-restricted in Rust. The UI reveals it only
        // when the user explicitly asks about network fees.
        feeReserveDetailsStack.axis = .vertical
        feeReserveDetailsStack.alignment = .center
        feeReserveDetailsStack.spacing = 12
        feeReserveDetailsStack.isHidden = true
        addHeader(
            OWSLocalizedString(
                "OPENCSV_WALLET_NETWORK_FEES",
                comment: "Heading above Bitcoin fee-reserve details.",
            ),
            to: feeReserveDetailsStack,
        )
        feeReserveLabel.font = .dynamicTypeBody
        feeReserveLabel.numberOfLines = 0
        feeReserveLabel.textAlignment = .center
        feeReserveDetailsStack.addArrangedSubview(feeReserveLabel)
        feeReserveExplanationLabel.font = .dynamicTypeFootnote
        feeReserveExplanationLabel.numberOfLines = 0
        feeReserveExplanationLabel.textColor = Theme.secondaryTextAndIconColor
        feeReserveExplanationLabel.text = OWSLocalizedString(
            "OPENCSV_WALLET_FEE_RESERVE_EXPLANATION",
            comment: "Explanation of the restricted Bitcoin fee reserve.",
        )
        feeReserveExplanationLabel.textAlignment = .center
        feeReserveDetailsStack.addArrangedSubview(feeReserveExplanationLabel)
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

        instrumentDetailsLabel.font = .dynamicTypeFootnote
        instrumentDetailsLabel.numberOfLines = 0
        instrumentDetailsLabel.textColor = Theme.secondaryTextAndIconColor
        advancedStack.addArrangedSubview(instrumentDetailsLabel)
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
        explorerButton.isHidden = true
        feeBumpButton = addButton(
            OWSLocalizedString(
                "OPENCSV_WALLET_FEE_BUMP",
                comment: "Button that raises the fee of an unconfirmed OpenCSV transaction.",
            ),
            action: #selector(didTapFeeBump),
        )
        feeBumpButton?.isEnabled = false
        feeBumpButton?.isHidden = true

        if SUIEnvironment.shared.paymentsRef.paymentsEntropy != nil {
            addHeader(
                OWSLocalizedString(
                    "OPENCSV_LEGACY_MOBILECOIN_TITLE",
                    comment: "Section header for legacy MobileCoin recovery material.",
                ),
                to: advancedStack,
            )
            let warning = UILabel()
            warning.font = .dynamicTypeCaption1
            warning.numberOfLines = 0
            warning.textColor = Theme.secondaryTextAndIconColor
            warning.text = OWSLocalizedString(
                "OPENCSV_LEGACY_MOBILECOIN_WARNING",
                comment: "Read-only warning shown when legacy MobileCoin recovery material remains on the device.",
            )
            advancedStack.addArrangedSubview(warning)
            addButton(
                OWSLocalizedString(
                    "OPENCSV_LEGACY_MOBILECOIN_EXPORT",
                    comment: "Button opening the protected export flow for a legacy MobileCoin recovery phrase.",
                ),
                action: #selector(didTapLegacyMobileCoinExport),
                to: advancedStack,
            )
        }

        // Advanced: the chain configuration, collapsed by default. These
        // are the same persisted settings as always; only their address
        // changed.
        advancedButton = addButton(
            OWSLocalizedString(
                "OPENCSV_WALLET_DETAILS",
                comment: "Disclosure button revealing wallet and chain details.",
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
                scanFromHeightField,
                "OPENCSV_WALLET_SCAN_FROM_HEIGHT_PLACEHOLDER",
                "Placeholder for the earliest Bitcoin height covered by the phone-owned OpenCSV scan.",
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
        scanFromHeightField.keyboardType = .numberPad
        scanFromHeightField.addTarget(self, action: #selector(scanFromHeightChanged), for: .editingDidEnd)
        networkField.addTarget(self, action: #selector(networkChanged), for: .editingDidEnd)
        stack.addArrangedSubview(advancedStack)

        refresh()
    }

    private func refresh() {
        Task {
            do {
                // Rendering the persisted account first keeps the wallet
                // useful while its two independent network views refresh.
                let cached = try await OpenCsvPayments.shared.walletSummary()
                self.render(cached, refreshState: .updating)

                async let accountSync = try? await OpenCsvPayments.shared.syncAccount()
                async let scanSync = OpenCsvPayments.shared.scanSyncIfNeeded()
                let (accountReport, scanSucceeded) = await (accountSync, scanSync)

                let updated = try await OpenCsvPayments.shared.walletSummary()
                // The fee accelerator succeeding does not make the chain
                // view authoritative. Freshness is "current" only after the
                // phone-owned headers/filter/block pass completes.
                _ = accountReport
                self.render(updated, refreshState: scanSucceeded ? .current : .failed)
            } catch {
                // Never erase a balance already rendered from disk merely
                // because its refresh failed. The placeholder is only for a
                // wallet that could not be opened at all.
                if self.balanceLabel.text == "—" {
                    self.balanceStatusLabel.text = OWSLocalizedString(
                        "OPENCSV_WALLET_SETUP_INCOMPLETE",
                        comment: "Status shown when the OpenCSV wallet has not been provisioned on this device.",
                    )
                    self.operationHistoryLabel.text = OWSLocalizedString(
                        "OPENCSV_WALLET_NO_ACTIVITY",
                        comment: "Shown when there are no OpenCSV wallet operations yet.",
                    )
                }
            }
        }
    }

    private func render(
        _ summary: OpenCsvPayments.WalletSummary,
        refreshState: RefreshState,
    ) {
        owner = summary.owner
        let usdSummary = Self.usdSummary(summary.balances, instruments: summary.instruments)
        balanceLabel.text = OpenCsvUsdAmount.format(usdSummary.total)
        let balanceStatus = usdSummary.hasConfiguredIssuer
            ? OWSLocalizedString(
                "OPENCSV_WALLET_USD_READY",
                comment: "Status below the USD balance when at least one reviewed issuer is configured.",
            )
            : OWSLocalizedString(
                "OPENCSV_WALLET_USD_NOT_AVAILABLE",
                comment: "Status below the USD balance when this build has no reviewed issuer configured.",
            )
        let confirmingCount = summary.incomingActivities.lazy.filter { $0.state == .confirming }.count
        let unconfirmedAvailableCount = summary.incomingActivities.lazy
            .filter { $0.state == .availableUnconfirmed }
            .count
        var statusLines = [balanceStatus]
        if unconfirmedAvailableCount > 0 {
            statusLines.append(String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "OPENCSV_WALLET_UNCONFIRMED_AVAILABLE_COUNT_FORMAT",
                    comment: "Wallet status for spendable incoming OpenCSV payments that are not settled. Embeds the count.",
                ),
                "\(unconfirmedAvailableCount)",
            ))
        }
        if confirmingCount > 0 {
            statusLines.append(String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "OPENCSV_WALLET_CONFIRMING_COUNT_FORMAT",
                    comment: "Wallet status for incoming OpenCSV payments still being verified. Embeds the count.",
                ),
                "\(confirmingCount)",
            ))
        }
        statusLines.append(Self.freshnessLine(summary: summary, refreshState: refreshState))
        balanceStatusLabel.text = statusLines.joined(separator: "\n")
        instrumentDetailsLabel.text = Self.renderHoldings(summary.balances, instruments: summary.instruments)
        ownerLabel.text = String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString(
                "OPENCSV_WALLET_RECEIVE_KEY_FORMAT",
                comment: "Abbreviated OpenCSV receiving key. Embeds {{ key prefix }} and {{ key suffix }}.",
            ),
            String(summary.owner.prefix(12)).lowercased(),
            String(summary.owner.suffix(8)).lowercased(),
        )
        qrImageView.image = Self.qrImage(for: summary.owner)
        bitcoinDepositAddress = summary.bitcoinDepositAddress
        bitcoinAddressLabel.text = summary.bitcoinDepositAddress
        bitcoinQrImageView.image = Self.qrImage(for: summary.bitcoinDepositAddress)
        feeReserveLabel.text = String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString(
                "OPENCSV_WALLET_FEE_RESERVE_FORMAT",
                comment: "Bitcoin fee reserve summary. Embeds {{ total sats }} and {{ confirmed sats }}.",
            ),
            "\(summary.feeReserve.totalSats)",
            "\(summary.feeReserve.confirmedSats)",
        )
        updateFeeAction(
            totalSats: summary.feeReserve.totalSats,
            confirmedSats: summary.feeReserve.confirmedSats,
        )
        utxoLabel.text = summary.feeReserve.utxos.isEmpty
            ? OWSLocalizedString(
                "OPENCSV_WALLET_NO_FEE_UTXOS",
                comment: "Shown in advanced wallet details when there are no Bitcoin fee UTXOs.",
            )
            : summary.feeReserve.utxos.map {
                "\($0.txid.prefix(10)): \($0.vout) · \($0.valueSats) sats\($0.reserved ? " · reserved" : "")"
            }.joined(separator: "\n")
        walletPolicyLabel.text = [
            "Bitcoin spending: OpenCSV fees only",
            "Backup: \(summary.backupVerified ? "verified" : "required")",
            "Device: \(summary.accountRole.rawValue), \(summary.deviceBindingStatus)",
            "Spend state: \(summary.syncProvenance.authoritative)",
        ].joined(separator: "\n")
        feeBumpCandidates = summary.operations.filter {
            ["broadcast_unobserved", "broadcast", "mempool"].contains($0.state)
        }
        let incomingActivity = summary.incomingActivities.suffix(8).reversed().map {
            Self.renderIncomingActivity($0)
        }
        let outgoingActivity = summary.operations.suffix(8).reversed().map {
            let txid = $0.txid.map { String($0.prefix(10)) } ?? "unsigned"
            return "\($0.kind) · \($0.state) · \(txid)"
        }
        let activity = incomingActivity + outgoingActivity
        operationHistoryLabel.text = activity.isEmpty
            ? OWSLocalizedString(
                "OPENCSV_WALLET_NO_ACTIVITY",
                comment: "Shown when there are no OpenCSV wallet operations yet.",
            )
            : activity.joined(separator: "\n")
        let latestTxid = summary.operations.reversed().compactMap(\.txid).first
        latestExplorerUrl = latestTxid.flatMap { txid in
            switch summary.network {
            case "mainnet": URL(string: "https://mempool.space/tx/\(txid)")
            case "signet": URL(string: "https://mempool.space/signet/tx/\(txid)")
            default: nil
            }
        }
        stack.viewWithTag(7301)?.isUserInteractionEnabled = latestExplorerUrl != nil
        (stack.viewWithTag(7301) as? UIButton)?.isEnabled = latestExplorerUrl != nil
        stack.viewWithTag(7301)?.isHidden = latestExplorerUrl == nil
        feeBumpButton?.isHidden = feeBumpCandidates.isEmpty
        feeBumpButton?.isEnabled = summary.writeEnabled && !writeInProgress && !feeBumpCandidates.isEmpty
        esploraField.text = summary.esploraUrl?.absoluteString
        spvPeersField.text = summary.spvPeers.joined(separator: ", ")
        scanFromHeightField.text = "\(summary.scanFromHeight)"
        networkField.text = summary.network
    }

    private static func freshnessLine(
        summary: OpenCsvPayments.WalletSummary,
        refreshState: RefreshState,
    ) -> String {
        guard let receipt = summary.verifiedChainView else {
            let key = refreshState == .failed
                ? "OPENCSV_WALLET_UPDATE_FAILED_SAVED"
                : "OPENCSV_WALLET_SAVED_UPDATING"
            return OWSLocalizedString(
                key,
                comment: "Wallet freshness when no phone-owned verified chain receipt has been persisted yet.",
            )
        }
        if refreshState == .current {
            return String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "OPENCSV_WALLET_VERIFIED_CURRENT_FORMAT",
                    comment: "Fresh wallet state. Embeds the verified Bitcoin block height.",
                ),
                "\(receipt.tipHeight)",
            )
        }
        let time = DateFormatter.localizedString(from: receipt.observedAt, dateStyle: .none, timeStyle: .short)
        let key = refreshState == .updating
            ? "OPENCSV_WALLET_VERIFIED_UPDATING_FORMAT"
            : "OPENCSV_WALLET_VERIFIED_UPDATE_FAILED_FORMAT"
        return String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString(
                key,
                comment: "Cached wallet freshness. Embeds the last verified time and Bitcoin block height.",
            ),
            time,
            "\(receipt.tipHeight)",
        )
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

    private static func renderIncomingActivity(_ activity: OpenCsvIncomingActivity) -> String {
        switch activity.state {
        case .confirming:
            return OWSLocalizedString(
                "OPENCSV_WALLET_ACTIVITY_CONFIRMING",
                comment: "Incoming wallet activity that is visible but not spendable.",
            )
        case .availableUnconfirmed:
            guard let amount = activity.amount else {
                return OWSLocalizedString(
                    "OPENCSV_WALLET_ACTIVITY_AVAILABLE_UNCONFIRMED",
                    comment: "Incoming wallet activity that is spendable before Bitcoin confirmation.",
                )
            }
            return String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "OPENCSV_WALLET_ACTIVITY_AVAILABLE_UNCONFIRMED_FORMAT",
                    comment: "Incoming wallet activity spendable before Bitcoin confirmation. Embeds amount and currency.",
                ),
                OpenCsvUsdAmount.format(amount),
                activity.currency ?? "USD",
            )
        case .available, .settled:
            guard let amount = activity.amount else {
                return OWSLocalizedString(
                    "OPENCSV_WALLET_ACTIVITY_AVAILABLE",
                    comment: "Incoming wallet activity that has become spendable.",
                )
            }
            return String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "OPENCSV_WALLET_ACTIVITY_AVAILABLE_FORMAT",
                    comment: "Incoming wallet activity that has become spendable. Embeds amount and currency.",
                ),
                OpenCsvUsdAmount.format(amount),
                activity.currency ?? "USD",
            )
        case .needsAttention:
            return OWSLocalizedString(
                "OPENCSV_WALLET_ACTIVITY_NEEDS_ATTENTION",
                comment: "Incoming wallet activity that failed definitive verification.",
            )
        }
    }

    private struct UsdSummary {
        let total: UInt64
        let hasConfiguredIssuer: Bool
    }

    private static func usdSummary(
        _ balances: [OpenCsvCredit],
        instruments: [OpenCsvInstrumentRecord],
    ) -> UsdSummary {
        let trustedIds = Set(instruments.compactMap { instrument -> String? in
            guard
                instrument.profile == "trusted_usd_v1",
                instrument.trustState == "trusted_configuration",
                instrument.manifest?.terms.unitCode == "USD",
                instrument.manifest?.terms.decimals == 6
            else { return nil }
            return instrument.assetId
        })
        let total = balances.lazy
            .filter { trustedIds.contains($0.assetId) }
            .reduce(UInt64(0)) { partial, balance in
                let (combined, overflow) = partial.addingReportingOverflow(balance.amount)
                return overflow ? UInt64.max : combined
            }
        return UsdSummary(total: total, hasConfiguredIssuer: !trustedIds.isEmpty)
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
    private func didTapReceive() {
        let shouldShow = receiveDetailsStack.isHidden
        setReceiveDetailsVisible(shouldShow)
        if shouldShow {
            setFeeReserveDetailsVisible(false)
            setAdvancedVisible(false)
        }
    }

    private func setReceiveDetailsVisible(_ isVisible: Bool) {
        receiveDetailsStack.isHidden = !isVisible
        receiveButton?.configuration?.title = isVisible
            ? OWSLocalizedString(
                "OPENCSV_WALLET_HIDE_RECEIVE",
                comment: "Action for hiding the OpenCSV receiving code.",
            )
            : OWSLocalizedString(
                "OPENCSV_WALLET_RECEIVE",
                comment: "Action for revealing the OpenCSV receiving code.",
            )
    }

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
        let shouldShow = feeReserveDetailsStack.isHidden
        setFeeReserveDetailsVisible(shouldShow)
        if shouldShow {
            setReceiveDetailsVisible(false)
            setAdvancedVisible(false)
        }
    }

    private func setFeeReserveDetailsVisible(_ isVisible: Bool) {
        feeReserveDetailsStack.isHidden = !isVisible
        feeReserveDetailsButton?.configuration?.title = isVisible
            ? OWSLocalizedString(
                "OPENCSV_WALLET_HIDE_NETWORK_FEES",
                comment: "Action for hiding Bitcoin fee-reserve details.",
            )
            : OWSLocalizedString(
                "OPENCSV_WALLET_NETWORK_FEES",
                comment: "Action for viewing and funding the Bitcoin fee reserve.",
            )
    }

    @objc
    private func didTapAdvanced() {
        let shouldShow = advancedStack.isHidden
        setAdvancedVisible(shouldShow)
        if shouldShow {
            setReceiveDetailsVisible(false)
            setFeeReserveDetailsVisible(false)
        }
    }

    private func setAdvancedVisible(_ isVisible: Bool) {
        advancedStack.isHidden = !isVisible
        let key = isVisible
            ? "OPENCSV_WALLET_HIDE_DETAILS"
            : "OPENCSV_WALLET_DETAILS"
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
    private func scanFromHeightChanged() {
        guard
            let text = scanFromHeightField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            let height = UInt64(text),
            height > 0
        else {
            refresh()
            return
        }
        Task { await OpenCsvPayments.shared.setScanFromHeight(height) }
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

    private func addHeader(_ text: String, to parent: UIStackView? = nil) {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .dynamicTypeCaption1
        label.textColor = Theme.secondaryTextAndIconColor
        let target = parent ?? stack
        target.setCustomSpacing(24, after: target.arrangedSubviews.last ?? label)
        target.addArrangedSubview(label)
    }

    private func makeActionButton(
        title: String,
        subtitle: String?,
        imageName: String,
        action: Selector,
    ) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.image = UIImage(systemName: imageName)
        configuration.imagePlacement = .top
        configuration.imagePadding = 8
        configuration.baseForegroundColor = Theme.primaryTextColor
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 14,
            leading: 12,
            bottom: 14,
            trailing: 12,
        )
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        return button
    }

    private func updateFeeAction(totalSats: UInt64, confirmedSats: UInt64) {
        let subtitle: String
        if totalSats == 0 {
            subtitle = OWSLocalizedString(
                "OPENCSV_WALLET_FEES_EMPTY",
                comment: "Network-fee action subtitle when the Bitcoin fee reserve is empty.",
            )
        } else if confirmedSats == 0 {
            subtitle = String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "OPENCSV_WALLET_FEES_PENDING_FORMAT",
                    comment: "Network-fee action subtitle for unconfirmed sats. Embeds {{ total sats }}.",
                ),
                "\(totalSats)",
            )
        } else {
            subtitle = String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "OPENCSV_WALLET_FEES_READY_FORMAT",
                    comment: "Network-fee action subtitle for confirmed sats. Embeds {{ confirmed sats }}.",
                ),
                "\(confirmedSats)",
            )
        }
        feeReserveDetailsButton?.configuration?.subtitle = subtitle
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
