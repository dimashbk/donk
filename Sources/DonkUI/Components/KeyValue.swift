import SwiftUI

// MARK: - Model

public struct DonkKeyValue: Hashable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public init(_ key: String, _ value: String) {
        self.init(key: key, value: value)
    }

    public static func text(for items: [DonkKeyValue], separator: String = ": ") -> String {
        items.map { $0.key + separator + $0.value }.joined(separator: "\n")
    }
}

// MARK: - Row

public enum DonkKeyValueLayout: Hashable, Sendable {
    case horizontal
    case vertical
}

public struct KeyValueRow: View {
    private let key: String
    private let value: String
    private let monospacedValue: Bool
    private let layout: DonkKeyValueLayout
    private let valueTone: DonkTone?
    private let keyWidth: CGFloat?
    private let masksValue: Bool
    @State private var isRevealed = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var scale: CGFloat = 1

    private static let displayLimit = 4000
    public static let maskText = "••••"

    public init(
        key: String,
        value: String,
        monospacedValue: Bool = false,
        layout: DonkKeyValueLayout = .horizontal,
        valueTone: DonkTone? = nil,
        keyWidth: CGFloat? = 112,
        masksValue: Bool = false
    ) {
        self.key = key
        self.value = value
        self.monospacedValue = monospacedValue
        self.layout = layout
        self.valueTone = valueTone
        self.keyWidth = keyWidth
        self.masksValue = masksValue
    }

    private var isMasked: Bool {
        masksValue && !isRevealed && !value.isEmpty
    }

    public var body: some View {
        Group {
            if layout == .vertical || dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    keyText
                    valueText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DonkSpacing.m) {
                    keyText
                        .frame(width: keyWidth.map { $0 * scale }, alignment: .leading)
                    valueText
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .modifier(RevealTapModifier(isEnabled: masksValue, action: toggleReveal))
        .contextMenu {
            if masksValue {
                Button {
                    toggleReveal()
                } label: {
                    Label(isRevealed ? "Hide Value" : "Reveal Value", systemImage: isRevealed ? "eye.slash" : "eye")
                }
            }
            Button {
                DonkPasteboard.copy(value, label: "Value")
            } label: {
                Label("Copy Value", systemImage: "doc.on.doc")
            }
            Button {
                DonkPasteboard.copy(key, label: "Key")
            } label: {
                Label("Copy Key", systemImage: "key")
            }
            Button {
                DonkPasteboard.copy("\(key): \(value)")
            } label: {
                Label("Copy Key & Value", systemImage: "text.badge.plus")
            }
        }
        .accessibilityElement(children: .combine)
        .modifier(RevealAccessibilityModifier(isEnabled: masksValue, isRevealed: isRevealed, action: toggleReveal))
    }

    private func toggleReveal() {
        DonkHaptics.selection()
        withAnimation(.easeOut(duration: 0.15)) {
            isRevealed.toggle()
        }
    }

    private var keyText: some View {
        Text(DonkTextBreaking.breakableKey(key))
            .font(.footnote.weight(.medium))
            .foregroundColor(DonkColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var valueText: some View {
        if isMasked {
            HStack(spacing: 6) {
                Text(Self.maskText)
                    .font(monospacedValue ? DonkFont.code : .footnote)
                    .foregroundColor(DonkColor.textSecondary)
                Image(systemName: "eye")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(DonkColor.textTertiary)
                    .accessibilityHidden(true)
            }
        } else {
            Text(displayValue)
                .font(monospacedValue ? DonkFont.code : .footnote)
                .foregroundColor(valueTone?.color ?? DonkColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayValue: String {
        if value.isEmpty { return "—" }
        guard value.count > Self.displayLimit else { return DonkTextBreaking.breakable(value) }
        return DonkTextBreaking.breakable(value.prefix(Self.displayLimit)) + "…"
    }
}

private struct RevealTapModifier: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

private struct RevealAccessibilityModifier: ViewModifier {
    let isEnabled: Bool
    let isRevealed: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .accessibilityValue(isRevealed ? Text("") : Text("Hidden"))
                .accessibilityHint(Text(isRevealed ? "Double-tap to hide the value" : "Double-tap to reveal the value"))
                .accessibilityAction(named: Text(isRevealed ? "Hide value" : "Reveal value"), action)
        } else {
            content
        }
    }
}

// MARK: - Header list

public struct HeaderListView: View {
    private let items: [DonkKeyValue]
    private let title: String?
    private let monospacedValues: Bool
    private let emptyText: String
    private let embedInCard: Bool
    private let keyWidth: CGFloat?
    private let masksKey: ((String) -> Bool)?

    public init(
        _ items: [DonkKeyValue],
        title: String? = nil,
        monospacedValues: Bool = true,
        emptyText: String = "No headers",
        embedInCard: Bool = true,
        keyWidth: CGFloat? = 120,
        masksKey: ((String) -> Bool)? = nil
    ) {
        self.items = items
        self.title = title
        self.monospacedValues = monospacedValues
        self.emptyText = emptyText
        self.embedInCard = embedInCard
        self.keyWidth = keyWidth
        self.masksKey = masksKey
    }

    public init(
        _ pairs: [(String, String)],
        title: String? = nil,
        monospacedValues: Bool = true,
        emptyText: String = "No headers",
        embedInCard: Bool = true,
        keyWidth: CGFloat? = 120,
        masksKey: ((String) -> Bool)? = nil
    ) {
        self.init(
            pairs.map { DonkKeyValue(key: $0.0, value: $0.1) },
            title: title,
            monospacedValues: monospacedValues,
            emptyText: emptyText,
            embedInCard: embedInCard,
            keyWidth: keyWidth,
            masksKey: masksKey
        )
    }

    private func isMasked(_ item: DonkKeyValue) -> Bool {
        masksKey?(item.key) ?? false
    }

    public var body: some View {
        if embedInCard {
            DonkCard(title: title) {
                rows
            } accessory: {
                accessory
            }
        } else {
            VStack(alignment: .leading, spacing: DonkSpacing.xs) {
                HStack {
                    if let title {
                        Text(title)
                            .font(DonkFont.rounded(.subheadline, weight: .semibold))
                    }
                    Spacer(minLength: DonkSpacing.s)
                    accessory
                        .font(DonkFont.label)
                }
                rows
            }
        }
    }

    @ViewBuilder
    private var accessory: some View {
        if !items.isEmpty {
            HStack(spacing: DonkSpacing.s) {
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(DonkColor.textTertiary)
                CopyButton(label: title ?? "All") {
                    DonkKeyValue.text(for: items.map { item in
                        isMasked(item) && !item.value.isEmpty ? DonkKeyValue(item.key, KeyValueRow.maskText) : item
                    })
                }
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        if items.isEmpty {
            Text(emptyText)
                .font(.footnote)
                .foregroundColor(DonkColor.textTertiary)
                .padding(.vertical, DonkSpacing.xs)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    KeyValueRow(
                        key: item.key,
                        value: item.value,
                        monospacedValue: monospacedValues,
                        keyWidth: keyWidth,
                        masksValue: isMasked(item)
                    )
                    if index < items.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }
}

// MARK: - Copy button

public struct CopyButton: View {
    private let value: () -> String
    private let label: String?
    private let title: String?
    @State private var copied = false

    public init(text: String, label: String? = nil, title: String? = nil) {
        self.value = { text }
        self.label = label
        self.title = title
    }

    public init(label: String? = nil, title: String? = nil, value: @escaping () -> String) {
        self.value = value
        self.label = label
        self.title = title
    }

    public var body: some View {
        Button {
            DonkPasteboard.copy(value(), label: label)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                copied = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.footnote.weight(.semibold))
                    .frame(minWidth: 16)
                    .transition(.scale.combined(with: .opacity))
                    .id(copied)
                if let title {
                    Text(copied ? "Copied" : title)
                        .font(.footnote.weight(.semibold))
                }
            }
            .foregroundColor(copied ? DonkColor.success : DonkColor.accent)
            .frame(minWidth: 32, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title ?? "Copy")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                copied = false
            }
        }
    }
}
