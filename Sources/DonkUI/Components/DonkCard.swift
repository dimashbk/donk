import SwiftUI

// MARK: - Card

public struct DonkCard<Content: View, Accessory: View>: View {
    private let title: String?
    private let icon: String?
    private let tone: DonkTone
    private let padding: CGFloat
    private let content: Content
    private let accessory: Accessory

    public init(
        title: String? = nil,
        icon: String? = nil,
        tone: DonkTone = .accent,
        padding: CGFloat = DonkSpacing.l,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.icon = icon
        self.tone = tone
        self.padding = padding
        self.content = content()
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.m) {
            if hasHeader {
                header
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)
                .fill(DonkColor.card)
        )
    }

    private var hasHeader: Bool {
        title != nil || icon != nil || Accessory.self != EmptyView.self
    }

    private var header: some View {
        HStack(spacing: DonkSpacing.s) {
            if let icon {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(tone.color)
                    .accessibilityHidden(true)
            }
            if let title {
                Text(title)
                    .font(DonkFont.rounded(.subheadline, weight: .semibold))
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: DonkSpacing.s)
            accessory
                .font(DonkFont.label)
                .tint(DonkColor.accent)
        }
    }
}

public extension DonkCard where Accessory == EmptyView {
    init(
        title: String? = nil,
        icon: String? = nil,
        tone: DonkTone = .accent,
        padding: CGFloat = DonkSpacing.l,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, icon: icon, tone: tone, padding: padding, content: content) { EmptyView() }
    }
}

// MARK: - Section header

public struct DonkSectionHeader<Trailing: View>: View {
    private let title: String
    private let icon: String?
    private let count: Int?
    private let trailing: Trailing

    public init(_ title: String, icon: String? = nil, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self.count = count
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .textCase(.uppercase)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text(DonkFormat.compact(count))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DonkColor.fill))
            }
            Spacer(minLength: DonkSpacing.s)
            trailing
                .textCase(nil)
        }
        .font(.footnote.weight(.semibold))
        .foregroundColor(DonkColor.textSecondary)
    }
}

public extension DonkSectionHeader where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil, count: Int? = nil) {
        self.init(title, icon: icon, count: count) { EmptyView() }
    }
}

// MARK: - Icon badge

public struct DonkIconBadge: View {
    private let systemName: String
    private let tone: DonkTone
    private let size: CGFloat
    private let filled: Bool

    public init(_ systemName: String, tone: DonkTone = .accent, size: CGFloat = 32, filled: Bool = false) {
        self.systemName = systemName
        self.tone = tone
        self.size = size
        self.filled = filled
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(filled ? tone.color : tone.softBackground)
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundColor(filled ? .white : tone.color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Label row

public struct DonkLabelRow<Trailing: View>: View {
    private let icon: String?
    private let tone: DonkTone
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    public init(
        icon: String? = nil,
        tone: DonkTone = .accent,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.tone = tone
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: DonkSpacing.m) {
            if let icon {
                DonkIconBadge(icon, tone: tone, size: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(DonkColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: DonkSpacing.s)
            trailing
                .font(.subheadline)
                .foregroundColor(DonkColor.textSecondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

public extension DonkLabelRow where Trailing == EmptyView {
    init(icon: String? = nil, tone: DonkTone = .accent, title: String, subtitle: String? = nil) {
        self.init(icon: icon, tone: tone, title: title, subtitle: subtitle) { EmptyView() }
    }
}

public extension DonkLabelRow where Trailing == Text {
    init(icon: String? = nil, tone: DonkTone = .accent, title: String, subtitle: String? = nil, value: String) {
        self.init(icon: icon, tone: tone, title: title, subtitle: subtitle) { Text(value) }
    }
}
