import SwiftUI

// MARK: - Filter chip

public struct FilterChip: View {
    private let title: String
    private let icon: String?
    private let isOn: Bool
    private let tone: DonkTone
    private let count: Int?
    private let action: () -> Void

    public init(title: String, icon: String? = nil, isOn: Binding<Bool>, tone: DonkTone = .accent, count: Int? = nil) {
        self.title = title
        self.icon = icon
        self.isOn = isOn.wrappedValue
        self.tone = tone
        self.count = count
        self.action = { isOn.wrappedValue.toggle() }
    }

    public init(
        title: String,
        icon: String? = nil,
        isSelected: Bool,
        tone: DonkTone = .accent,
        count: Int? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isOn = isSelected
        self.tone = tone
        self.count = count
        self.action = action
    }

    public var body: some View {
        Button {
            DonkHaptics.selection()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                action()
            }
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .symbolRenderingMode(.hierarchical)
                        .font(.caption.weight(.semibold))
                }
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if let count {
                    Text(DonkFormat.compact(count))
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isOn ? tone.color.opacity(0.18) : DonkColor.fill))
                }
            }
            .foregroundColor(isOn ? tone.color : DonkColor.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(isOn ? tone.softBackground : DonkColor.card))
            .overlay(
                Capsule().strokeBorder(
                    isOn ? tone.color.opacity(0.45) : DonkColor.separator.opacity(0.7),
                    lineWidth: isOn ? 1 : 0.5
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.donkPressable)
        .accessibilityLabel(title)
        .accessibilityValue(count.map { "\($0)" } ?? "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Chip row

public struct ChipRow<Content: View>: View {
    private let spacing: CGFloat
    private let horizontalPadding: CGFloat
    private let content: Content

    public init(spacing: CGFloat = DonkSpacing.s, horizontalPadding: CGFloat = DonkSpacing.l, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.horizontalPadding = horizontalPadding
        self.content = content()
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                content
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Empty state

public struct EmptyStateView: View {
    private let icon: String
    private let title: String
    private let message: String?
    private let tone: DonkTone
    private let actionTitle: String?
    private let action: (() -> Void)?
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 30
    @ScaledMetric(relativeTo: .title) private var circleSize: CGFloat = 76

    public init(
        icon: String,
        title: String,
        message: String? = nil,
        tone: DonkTone = .accent,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.tone = tone
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tone.softBackground)
                    .frame(width: circleSize, height: circleSize)
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(tone.color)
            }
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(DonkFont.title3)
                    .foregroundColor(DonkColor.textPrimary)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(DonkColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(tone.color)
                .buttonBorderShape(.capsule)
                .padding(.top, DonkSpacing.xs)
            }
        }
        .padding(DonkSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Segmented tabs

public struct SegmentedTabs<Tab: Hashable>: View {
    @Binding private var selection: Tab
    private let tabs: [Tab]
    private let title: (Tab) -> String
    private let icon: ((Tab) -> String?)?
    private let badge: ((Tab) -> Int?)?
    @Namespace private var namespace

    public init(
        selection: Binding<Tab>,
        tabs: [Tab],
        title: @escaping (Tab) -> String,
        icon: ((Tab) -> String?)? = nil,
        badge: ((Tab) -> Int?)? = nil
    ) {
        self._selection = selection
        self.tabs = tabs
        self.title = title
        self.icon = icon
        self.badge = badge
    }

    public var body: some View {
        if tabs.count > 4 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    track(fill: false)
                }
                .onChange(of: selection) { value in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        proxy.scrollTo(value, anchor: .center)
                    }
                }
            }
        } else {
            track(fill: true)
        }
    }

    private func track(fill: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                segment(tab, fill: fill)
                    .id(tab)
            }
        }
        .padding(3)
        .background(Capsule().fill(DonkColor.fill))
    }

    private func segment(_ tab: Tab, fill: Bool) -> some View {
        let isSelected = tab == selection
        return Button {
            guard tab != selection else { return }
            DonkHaptics.selection()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                selection = tab
            }
        } label: {
            HStack(spacing: 5) {
                if let symbol = icon?(tab) {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.caption.weight(.semibold))
                }
                Text(title(tab))
                    .lineLimit(1)
                if let count = badge?(tab), count > 0 {
                    Text(DonkFormat.compact(count))
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundColor(isSelected ? DonkColor.accent : DonkColor.textTertiary)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(isSelected ? DonkColor.textPrimary : DonkColor.textSecondary)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .frame(maxWidth: fill ? .infinity : nil)
            .background {
                if isSelected {
                    Capsule()
                        .fill(DonkColor.segmentIndicator)
                        .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
                        .matchedGeometryEffect(id: "donk.segment.indicator", in: namespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
