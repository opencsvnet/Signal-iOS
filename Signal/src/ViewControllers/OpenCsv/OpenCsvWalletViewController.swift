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
    private let advancedStack = UIStackView()
    private let anchorServerField = UITextField()
    private let spvPeersField = UITextField()
    private let networkField = UITextField()
    private var owner: String?

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
                anchorServerField,
                "OPENCSV_SEND_ANCHOR_SERVER_PLACEHOLDER",
                "Placeholder for the anchor server URL field in the OpenCSV send sheet.",
            ),
        ] {
            field.placeholder = OWSLocalizedString(placeholderKey, comment: placeholderComment)
            field.borderStyle = .roundedRect
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            advancedStack.addArrangedSubview(field)
        }
        anchorServerField.addTarget(self, action: #selector(anchorServerChanged), for: .editingDidEnd)
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
                self.anchorServerField.text = summary.anchorServerUrl?.absoluteString
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
    private func didTapAdvanced() {
        advancedStack.isHidden.toggle()
    }

    @objc
    private func anchorServerChanged() {
        let url = anchorServerField.text?.strippedOrNil
        Task { await OpenCsvPayments.shared.setAnchorServerUrl(url) }
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

    private func addButton(_ title: String, action: Selector) {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .dynamicTypeBody
        button.addTarget(self, action: action, for: .touchUpInside)
        stack.addArrangedSubview(button)
    }
}
