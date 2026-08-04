//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// The phone-as-explorer: the detail sheet behind a tapped OpenCSV
/// payment bubble. There is no explorer website because the phone is the
/// explorer — this sheet shows the evidence this device gathered for (or
/// against) the payment: the verdict and its provenance, the anchor's
/// place on the chain with live confirmations against the phone's own
/// tip, and what the chain view cost to build.
class OpenCsvPaymentExplorerViewController: OWSViewController {

    private let attachmentId: Attachment.IDType

    private let stack = UIStackView()
    private let scrollView = UIScrollView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var detail: OpenCsvPayments.ExplorerDetail?

    init(attachmentId: Attachment.IDType) {
        self.attachmentId = attachmentId
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = OWSLocalizedString(
            "OPENCSV_EXPLORER_TITLE",
            comment: "Title of the OpenCSV payment detail (explorer) sheet.",
        )
        view.backgroundColor = Theme.backgroundColor
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(didTapDone),
        )

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

        spinner.startAnimating()
        stack.addArrangedSubview(spinner)
        reload()
    }

    private func reload() {
        let attachmentId = self.attachmentId
        Task {
            let detail = await OpenCsvPayments.shared.explorerDetail(attachmentId: attachmentId)
            self.detail = detail
            self.render(detail)
        }
    }

    // MARK: - Rendering

    private func render(_ detail: OpenCsvPayments.ExplorerDetail) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        renderPaymentSection(detail)
        renderProvenanceSection(detail)
        renderChainEvidenceSection(detail)
        renderChainViewSection(detail)
        renderActionsSection(detail)
    }

    private func renderPaymentSection(_ detail: OpenCsvPayments.ExplorerDetail) {
        if let verdict = detail.verdict {
            let sign = verdict.direction == .outgoing ? "−" : "+"
            let amount = verdict.direction == .thirdParty
                ? OWSLocalizedString(
                    "OPENCSV_PAYMENT_AMOUNT_NOT_YOURS",
                    comment: "Shown in an OpenCSV payment bubble for a verified payment that pays neither party.",
                )
                : "\(sign)\(verdict.amount) \(verdict.currency ?? "")"
            addTitle(amount.ows_stripped(), font: UIFont.dynamicTypeLargeTitle1Clamped.withSize(34))
            addKeyValue(
                key: OWSLocalizedString("OPENCSV_EXPLORER_DATE", comment: "Label for the verification date row."),
                value: DateFormatter.localizedString(from: verdict.verifiedAt, dateStyle: .medium, timeStyle: .medium),
            )
        } else {
            addTitle(OWSLocalizedString(
                "OPENCSV_PAYMENT_STATUS_PENDING",
                comment: "Status shown in an OpenCSV payment bubble while the proof has not been verified yet.",
            ), font: .dynamicTypeTitle2)
        }
    }

    private func renderProvenanceSection(_ detail: OpenCsvPayments.ExplorerDetail) {
        // The differentiator line: how this payment was believed — and by
        // whom, which for self-scan is nobody but this phone.
        let provenance: String
        if let verdict = detail.verdict {
            if verdict.isVerified {
                if verdict.finality == "unconfirmed" {
                    provenance = OWSLocalizedString(
                        "OPENCSV_EXPLORER_PROVENANCE_UNCONFIRMED",
                        comment: "Provenance for a proof-verified payment whose exact mempool anchor is spendable before settlement.",
                    )
                } else {
                    switch verdict.chainView {
                    case "self-scan":
                        provenance = OWSLocalizedString(
                            "OPENCSV_EXPLORER_PROVENANCE_SELF_SCAN",
                            comment: "Provenance line for a payment this phone verified against the chain with no server.",
                        )
                    case "cross-check":
                        provenance = OWSLocalizedString(
                            "OPENCSV_EXPLORER_PROVENANCE_CROSS_CHECK",
                            comment: "Provenance line for a payment verified by cross-checking independent indexers.",
                        )
                    default:
                        provenance = OWSLocalizedString(
                            "OPENCSV_EXPLORER_PROVENANCE_SNAPSHOT",
                            comment: "Provenance line for a payment verified against a single anchor snapshot.",
                        )
                    }
                }
            } else {
                let format = OWSLocalizedString(
                    "OPENCSV_EXPLORER_REJECTED_FORMAT",
                    comment: "Provenance line for a rejected payment. Embeds {{ the rejection reason }}.",
                )
                provenance = String.nonPluralLocalizedStringWithFormat(format, verdict.reason ?? "")
            }
        } else if let withheld = detail.withheldReason {
            let format = OWSLocalizedString(
                "OPENCSV_EXPLORER_WITHHELD_FORMAT",
                comment: "Provenance line while verification is retryable. Embeds {{ the last failure reason }}.",
            )
            provenance = String.nonPluralLocalizedStringWithFormat(format, withheld)
        } else {
            provenance = OWSLocalizedString(
                "OPENCSV_EXPLORER_WITHHELD_NO_ATTEMPT",
                comment: "Provenance line while verification has not yet been attempted.",
            )
        }
        addBody(provenance, emphasized: detail.verdict?.isVerified == true)

        if detail.verdict?.isVerified == true {
            let exclusion = detail.verdict?.finality == "unconfirmed"
                ? OWSLocalizedString(
                    "OPENCSV_EXPLORER_EXCLUSION_UNCONFIRMED",
                    comment: "Plain-language mempool ordering and replacement disclosure for a zero-confirmation payment.",
                )
                : OWSLocalizedString(
                    "OPENCSV_EXPLORER_EXCLUSION",
                    comment: "Plain-language double-spend result shown for a settled OpenCSV payment.",
                )
            addBody(exclusion, emphasized: false)
        }
    }

    private func renderChainEvidenceSection(_ detail: OpenCsvPayments.ExplorerDetail) {
        guard let height = detail.anchorHeight else { return }
        addSectionHeader(OWSLocalizedString(
            "OPENCSV_EXPLORER_SECTION_ANCHOR",
            comment: "Section header for the on-chain anchor evidence.",
        ))
        addKeyValue(
            key: OWSLocalizedString("OPENCSV_EXPLORER_ANCHOR_LOCATION", comment: "Label for the anchor's block height and position."),
            value: "\(height) : \(detail.anchorPosition ?? 0)",
        )
        if let confirmations = detail.confirmations, let tip = detail.tipHeight {
            let format = OWSLocalizedString(
                "OPENCSV_EXPLORER_CONFIRMATIONS_FORMAT",
                comment: "Confirmations row. Embeds {{ confirmation count }} and {{ the phone's synced tip height }}.",
            )
            addKeyValue(
                key: OWSLocalizedString("OPENCSV_EXPLORER_CONFIRMATIONS", comment: "Label for the confirmations row."),
                value: String(format: format, "\(confirmations)", "\(tip)"),
            )
        }
        if let txid = detail.txidHex {
            addCopyableRow(
                key: OWSLocalizedString("OPENCSV_EXPLORER_TXID", comment: "Label for the anchor transaction id row."),
                value: txid,
            )
            if let url = Self.externalExplorerUrl(network: detail.network, txid: txid) {
                addLinkRow(
                    title: OWSLocalizedString(
                        "OPENCSV_EXPLORER_VIEW_EXTERNAL",
                        comment: "Button opening the anchor transaction on a public block explorer.",
                    ),
                    url: url,
                )
            }
        }
        if let record = detail.recordHex {
            addCopyableRow(
                key: OWSLocalizedString("OPENCSV_EXPLORER_RECORD", comment: "Label for the 64-byte anchor record row."),
                value: record,
            )
        }
        if let ctx = detail.ctxHex {
            addCopyableRow(
                key: OWSLocalizedString("OPENCSV_EXPLORER_CTX", comment: "Label for the anchor binding context row."),
                value: ctx,
            )
        }
    }

    private func renderChainViewSection(_ detail: OpenCsvPayments.ExplorerDetail) {
        guard let sync = detail.syncSummary else { return }
        addSectionHeader(OWSLocalizedString(
            "OPENCSV_EXPLORER_SECTION_CHAIN_VIEW",
            comment: "Section header for the phone's own chain view stats.",
        ))
        addKeyValue(
            key: OWSLocalizedString("OPENCSV_EXPLORER_TIP", comment: "Label for the phone's synced chain tip."),
            value: "\(sync.tipHeight) (\(detail.network))",
        )
        addKeyValue(
            key: OWSLocalizedString("OPENCSV_EXPLORER_ANCHORS_INDEXED", comment: "Label for the number of anchors in the phone's index."),
            value: "\(sync.anchors)",
        )
        addKeyValue(
            key: OWSLocalizedString("OPENCSV_EXPLORER_SYNC_COST", comment: "Label for the bytes the last sync cost."),
            value: "\(sync.filtersBytes) B + \(sync.blocksBytes) B",
        )
    }

    private func renderActionsSection(_ detail: OpenCsvPayments.ExplorerDetail) {
        addSectionHeader("")
        if detail.blob != nil {
            addButton(
                title: OWSLocalizedString(
                    "OPENCSV_EXPLORER_REVERIFY",
                    comment: "Button that re-runs verification against the phone's current chain view.",
                ),
                action: #selector(didTapReverify),
            )
            addButton(
                title: OWSLocalizedString(
                    "OPENCSV_EXPLORER_SHARE_FILE",
                    comment: "Button that shares the raw consignment file.",
                ),
                action: #selector(didTapShareFile),
            )
        }
    }

    // MARK: - Actions

    @objc
    private func didTapDone() {
        dismiss(animated: true)
    }

    @objc
    private func didTapReverify() {
        let attachmentId = self.attachmentId
        spinnerRow()
        Task {
            do {
                let verified = try await OpenCsvPayments.shared.reVerify(attachmentId: attachmentId)
                let message = verified
                    ? OWSLocalizedString(
                        "OPENCSV_EXPLORER_REVERIFY_OK",
                        comment: "Toast shown when a live re-verification succeeds.",
                    )
                    : OWSLocalizedString(
                        "OPENCSV_EXPLORER_REVERIFY_FAILED",
                        comment: "Toast shown when a live re-verification does not verify.",
                    )
                self.presentToast(text: message)
            } catch {
                self.presentToast(text: "\(error)")
            }
            self.reload()
        }
    }

    @objc
    private func didTapShareFile() {
        guard let blob = detail?.blob else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencsv-consignment.bin")
        do {
            try blob.write(to: url)
            AttachmentSharing.showShareUI(for: url, sender: view, completion: nil)
        } catch {
            presentToast(text: "\(error)")
        }
    }

    // MARK: - Row helpers

    private static func externalExplorerUrl(network: String, txid: String) -> URL? {
        switch network {
        case "mainnet":
            return URL(string: "https://mempool.space/tx/\(txid)")
        case "signet":
            return URL(string: "https://mempool.space/signet/tx/\(txid)")
        case "mutinynet":
            return URL(string: "https://mutinynet.com/tx/\(txid)")
        default:
            // regtest and anything unknown: the phone's own evidence is
            // all there is — which is rather the point.
            return nil
        }
    }

    private func spinnerRow() {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        stack.addArrangedSubview(spinner)
    }

    private func addTitle(_ text: String, font: UIFont) {
        let label = UILabel()
        label.text = text
        label.font = font
        label.adjustsFontSizeToFitWidth = true
        stack.addArrangedSubview(label)
    }

    private func addSectionHeader(_ text: String) {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .dynamicTypeCaption1
        label.textColor = Theme.secondaryTextAndIconColor
        stack.setCustomSpacing(24, after: stack.arrangedSubviews.last ?? label)
        stack.addArrangedSubview(label)
    }

    private func addBody(_ text: String, emphasized: Bool) {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = emphasized ? .dynamicTypeHeadline : .dynamicTypeBody
        stack.addArrangedSubview(label)
    }

    private func addKeyValue(key: String, value: String) {
        let label = UILabel()
        label.numberOfLines = 0
        let attributed = NSMutableAttributedString(
            string: key + "  ",
            attributes: [.font: UIFont.dynamicTypeFootnote, .foregroundColor: Theme.secondaryTextAndIconColor],
        )
        attributed.append(NSAttributedString(
            string: value,
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: Theme.primaryTextColor],
        ))
        label.attributedText = attributed
        stack.addArrangedSubview(label)
    }

    private func addCopyableRow(key: String, value: String) {
        addKeyValue(key: key, value: value)
        guard let label = stack.arrangedSubviews.last as? UILabel else { return }
        label.isUserInteractionEnabled = true
        let tap = CopyTapGestureRecognizer(target: self, action: #selector(didTapCopyRow(_:)))
        tap.payload = value
        label.addGestureRecognizer(tap)
    }

    @objc
    private func didTapCopyRow(_ sender: CopyTapGestureRecognizer) {
        UIPasteboard.general.string = sender.payload
        presentToast(text: OWSLocalizedString(
            "OPENCSV_EXPLORER_COPIED",
            comment: "Toast confirming a value was copied to the clipboard.",
        ))
    }

    private func addLinkRow(title: String, url: URL) {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .dynamicTypeBody
        button.addAction(UIAction { _ in UIApplication.shared.open(url) }, for: .touchUpInside)
        stack.addArrangedSubview(button)
    }

    private func addButton(title: String, action: Selector) {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .dynamicTypeHeadline
        button.addTarget(self, action: action, for: .touchUpInside)
        stack.addArrangedSubview(button)
    }
}

/// A tap recognizer carrying the string it copies.
private class CopyTapGestureRecognizer: UITapGestureRecognizer {
    var payload: String = ""
}
