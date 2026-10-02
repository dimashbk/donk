import SwiftUI

// MARK: - Metric tile

public struct MetricTile: View {
    private let title: String
    private let value: String
    private let unit: String?
    private let tone: DonkTone
    private let icon: String?
    private let sparkline: [Double]?
    private let sparklineRange: ClosedRange<Double>?
    private let footnote: String?

    public init(
        title: String,
        value: String,
        unit: String? = nil,
        tone: DonkTone = .accent,
        icon: String? = nil,
        sparkline: [Double]? = nil,
        sparklineRange: ClosedRange<Double>? = nil,
        footnote: String? = nil
    ) {
        self.title = title
        self.value = value
        self.unit = unit
        self.tone = tone
        self.icon = icon
        self.sparkline = sparkline
        self.sparklineRange = sparklineRange
        self.footnote = footnote
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.s) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .symbolRenderingMode(.hierarchical)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(tone.color)
                } else {
                    Circle()
                        .fill(tone.color)
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: unit == "%" ? 1 : 3) {
                Text(value)
                    .font(DonkFont.metric)
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(1)
                }
            }
            if let sparkline {
                SparklineView(values: sparkline, range: sparklineRange, tone: tone)
                    .frame(height: 34)
            }
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundColor(DonkColor.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .donkCardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value, unit].compactMap { $0 }.joined(separator: " "))
    }
}

// MARK: - Tool tile

public struct ToolTile<Accessory: View>: View {
    private let icon: String
    private let title: String
    private let subtitle: String?
    private let tone: DonkTone
    private let badge: Int?
    private let accessory: Accessory

    public init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        tone: DonkTone = .accent,
        badge: Int? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.badge = badge
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.m) {
            HStack(alignment: .center, spacing: DonkSpacing.s) {
                DonkIconBadge(icon, tone: tone, size: Self.iconSize)
                Spacer(minLength: DonkSpacing.xs)
                if hasAccessory || (badge ?? 0) > 0 {
                    HStack(spacing: 6) {
                        if hasAccessory {
                            accessory
                        }
                        if let badge, badge > 0 {
                            CountBadge(badge, tone: tone == .neutral ? .error : tone)
                        }
                    }
                    .frame(maxHeight: Self.iconSize, alignment: .trailing)
                    .layoutPriority(1)
                }
            }
            .frame(height: Self.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DonkFont.rounded(.subheadline, weight: .semibold))
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                Text("A\nA")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .overlay(alignment: .topLeading) {
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundColor(DonkColor.textSecondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .accessibilityHidden(subtitle == nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
        .donkCardBackground()
        .contentShape(RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private static var iconSize: CGFloat { 36 }

    private var hasAccessory: Bool {
        Accessory.self != EmptyView.self
    }
}

public extension ToolTile where Accessory == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil, tone: DonkTone = .accent, badge: Int? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle, tone: tone, badge: badge) { EmptyView() }
    }
}
