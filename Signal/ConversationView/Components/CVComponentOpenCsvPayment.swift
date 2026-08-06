//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
public import SignalUI

/// Renders an OpenCSV consignment attachment as a payment bubble:
/// an amount line (`+100 Test USD`) and the client-side verification status.
/// Modeled on `CVComponentPaymentAttachment`.
public class CVComponentOpenCsvPayment: CVComponentBase, CVComponent {

    public var componentKey: CVComponentKey { .openCsvPayment }

    private let openCsvPayment: CVComponentState.OpenCsvPayment

    init(itemModel: CVItemModel, openCsvPayment: CVComponentState.OpenCsvPayment) {
        self.openCsvPayment = openCsvPayment
        super.init(itemModel: itemModel)
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewOpenCsvPayment()
    }

    public func configureForRendering(
        componentView componentViewParam: CVComponentView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
    ) {
        guard let componentView = componentViewParam as? CVComponentViewOpenCsvPayment else {
            owsFailDebug("Unexpected componentView.")
            componentViewParam.reset()
            return
        }

        titleLabelConfig.applyForRendering(label: componentView.titleLabel)
        amountLabelConfig.applyForRendering(label: componentView.amountLabel)
        statusLabelConfig.applyForRendering(label: componentView.statusLabel)

        componentView.vStackView.configure(
            config: vStackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: .measurementKey_vStack,
            subviews: [
                componentView.titleLabel,
                componentView.amountLabel,
                componentView.statusLabel,
            ],
        )
    }

    private var amountText: String {
        guard let verdict = openCsvPayment.verdict, verdict.isVerified else {
            return OWSLocalizedString(
                "OPENCSV_PAYMENT_AMOUNT_UNKNOWN",
                comment: "Placeholder shown in an OpenCSV payment bubble when no verified amount is available.",
            )
        }
        // A consignment that credits none of our coins is not a zero-value
        // payment — it is simply not ours, and must not render as "+0".
        guard verdict.direction != .thirdParty else {
            return OWSLocalizedString(
                "OPENCSV_PAYMENT_AMOUNT_NOT_YOURS",
                comment: "Shown in an OpenCSV payment bubble for a verified payment that pays neither party.",
            )
        }
        let currency = verdict.presentationCurrency
        // Outgoing amounts are what the recipient receives, so they read as
        // a debit; the change output is not part of the story.
        let sign = verdict.direction == .outgoing ? "−" : "+"
        return "\(sign)\(verdict.formattedAmount) \(currency)".ows_stripped()
    }

    private var statusText: String {
        guard let verdict = openCsvPayment.verdict else {
            return OWSLocalizedString(
                "OPENCSV_PAYMENT_STATUS_PENDING",
                comment: "Status shown in an OpenCSV payment bubble while the proof has not been verified yet.",
            )
        }
        if verdict.isVerified {
            if verdict.direction == .thirdParty {
                return OWSLocalizedString(
                    "OPENCSV_PAYMENT_STATUS_VERIFIED_NOT_YOURS",
                    comment: "Status for a verified OpenCSV payment that credits neither party in this chat.",
                )
            }
            if verdict.finality == "unconfirmed" {
                return OWSLocalizedString(
                    "OPENCSV_PAYMENT_STATUS_AVAILABLE_UNCONFIRMED",
                    comment: "Status for a verified payment that is spendable before Bitcoin confirmation.",
                )
            }
            // Self-scan means the phone checked the chain itself and
            // believed no server — a strictly stronger claim, so say so.
            if verdict.chainView == "self-scan" {
                return OWSLocalizedString(
                    "OPENCSV_PAYMENT_STATUS_VERIFIED_SELF_SCAN",
                    comment: "Status shown in an OpenCSV payment bubble when the proof verified against the phone's own chain scan, trusting no server.",
                )
            }
            return OWSLocalizedString(
                "OPENCSV_PAYMENT_STATUS_VERIFIED",
                comment: "Status shown in an OpenCSV payment bubble when the proof verified.",
            )
        }
        return OWSLocalizedString(
            "OPENCSV_PAYMENT_STATUS_FAILED",
            comment: "Status shown in an OpenCSV payment bubble when the proof failed verification.",
        )
    }

    private var vStackConfig: CVStackViewConfig {
        CVStackViewConfig(
            axis: .vertical,
            alignment: .leading,
            spacing: 4,
            layoutMargins: UIEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4),
        )
    }

    private var titleLabelConfig: CVLabelConfig {
        let title = if openCsvPayment.verdict?.direction == .minted {
            OWSLocalizedString(
                "OPENCSV_MINT_TITLE",
                comment: "Title of an OpenCSV asset issuance bubble in the conversation view.",
            )
        } else {
            OWSLocalizedString(
                "OPENCSV_PAYMENT_TITLE",
                comment: "Title of an OpenCSV payment bubble in the conversation view.",
            )
        }
        return CVLabelConfig.unstyledText(
            title,
            font: .dynamicTypeCaption1,
            textColor: conversationStyle.bubbleSecondaryTextColor(isIncoming: isIncoming),
        )
    }

    private var amountLabelConfig: CVLabelConfig {
        CVLabelConfig.unstyledText(
            amountText,
            font: UIFont.dynamicTypeLargeTitle1Clamped.withSize(28),
            textColor: conversationStyle.bubbleTextColor(isIncoming: isIncoming),
        )
    }

    private var statusLabelConfig: CVLabelConfig {
        CVLabelConfig.unstyledText(
            statusText,
            font: .dynamicTypeFootnote,
            textColor: conversationStyle.bubbleSecondaryTextColor(isIncoming: isIncoming),
        )
    }

    override public func handleTap(
        sender: UIGestureRecognizer,
        componentDelegate: CVComponentDelegate,
        componentView: CVComponentView,
        renderItem: CVRenderItem,
    ) -> Bool {
        // The phone is the explorer: the sheet shows the evidence this
        // device gathered for (or against) the payment.
        componentDelegate.didTapOpenCsvPayment(
            attachmentId: openCsvPayment.attachment.attachment.attachment.id,
        )
        return true
    }

    public func measure(
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        let maxLabelWidth = max(0, maxWidth - vStackConfig.layoutMargins.totalWidth)
        let titleSize = CVText.measureLabel(config: titleLabelConfig, maxWidth: maxLabelWidth)
        let amountSize = CVText.measureLabel(config: amountLabelConfig, maxWidth: maxLabelWidth)
        let statusSize = CVText.measureLabel(config: statusLabelConfig, maxWidth: maxLabelWidth)

        let measurement = ManualStackView.measure(
            config: vStackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: .measurementKey_vStack,
            subviewInfos: [
                titleSize.asManualSubviewInfo(),
                amountSize.asManualSubviewInfo(),
                statusSize.asManualSubviewInfo(),
            ],
        )
        return measurement.measuredSize
    }

    // MARK: - CVComponentView

    public class CVComponentViewOpenCsvPayment: NSObject, CVComponentView {

        fileprivate let vStackView = ManualStackView(name: "OpenCsvPayment.vStackView")
        fileprivate let titleLabel = CVLabel()
        fileprivate let amountLabel = CVLabel()
        fileprivate let statusLabel = CVLabel()

        public var isDedicatedCellView = true

        public var rootView: UIView {
            vStackView
        }

        public func setIsCellVisible(_ isCellVisible: Bool) {}

        public func reset() {
            vStackView.reset()
            titleLabel.text = nil
            amountLabel.text = nil
            statusLabel.text = nil
        }
    }
}

private extension String {
    static let measurementKey_vStack = "CVComponentOpenCsvPayment.measurementKey_vStack"
}

extension CVComponentOpenCsvPayment: CVAccessibilityComponent {
    public var accessibilityDescription: String {
        "\(amountText), \(statusText)"
    }
}
