import DonkUI
import SwiftUI

struct NumericKeypad: View {
    let title: String
    let unit: String
    let range: ClosedRange<Double>
    let allowsDecimal: Bool
    let onCommit: (Double) -> Void
    let onCancel: () -> Void
    @State private var text: String
    @State private var isNegative: Bool
    @State private var shakes = 0

    init(
        title: String,
        unit: String,
        range: ClosedRange<Double>,
        allowsDecimal: Bool,
        initialValue: Double,
        onCommit: @escaping (Double) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.unit = unit
        self.range = range
        self.allowsDecimal = allowsDecimal
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: UnitFormatter.number(CGFloat(abs(initialValue))))
        _isNegative = State(initialValue: initialValue < 0)
    }

    private var allowsNegative: Bool { range.lowerBound < 0 }

    private var value: Double? {
        guard let magnitude = Double(text.isEmpty ? "0" : text) else { return nil }
        return isNegative ? -magnitude : magnitude
    }

    private var isValid: Bool {
        guard let value else { return false }
        return range.contains(value)
    }

    private var rangeText: String {
        "\(UnitFormatter.number(CGFloat(range.lowerBound)))–\(UnitFormatter.number(CGFloat(range.upperBound)))\(unit.isEmpty ? "" : " \(unit)")"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title)
                    .font(DonkFont.rounded(.subheadline, weight: .semibold))
                Spacer()
                Button("Cancel", action: onCancel)
                    .font(.subheadline.weight(.medium))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if allowsNegative {
                    Button {
                        DonkHaptics.selection()
                        isNegative.toggle()
                    } label: {
                        Text("±")
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(DonkColor.fill))
                    }
                    .buttonStyle(.donkPressable)
                    .accessibilityLabel("Toggle sign")
                }
                Spacer()
                Text((isNegative ? "−" : "") + (text.isEmpty ? "0" : text))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(isValid ? DonkColor.textPrimary : DonkColor.error)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DonkColor.textSecondary)
                }
            }
            .modifier(ShakeEffect(shakes: CGFloat(shakes)))
            Text("Range \(rangeText)")
                .font(.caption)
                .foregroundColor(isValid ? DonkColor.textSecondary : DonkColor.error)
                .frame(maxWidth: .infinity, alignment: .trailing)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9"], id: \.self) { digit in
                    key(digit) { append(digit) }
                }
                if allowsDecimal {
                    key(".") { append(".") }
                } else {
                    Color.clear.frame(height: 44)
                }
                key("0") { append("0") }
                key(symbol: "delete.left", label: "Delete") {
                    if !text.isEmpty { text.removeLast() }
                }
            }
            Button {
                commit()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundColor(.white)
                    .background(Capsule().fill(DonkColor.accent))
            }
            .buttonStyle(.donkPressable)
        }
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            DonkHaptics.selection()
            action()
        } label: {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundColor(DonkColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DonkColor.card))
        }
        .buttonStyle(.donkPressable)
    }

    private func key(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            DonkHaptics.selection()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundColor(DonkColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DonkColor.card))
        }
        .buttonStyle(.donkPressable)
        .accessibilityLabel(label)
    }

    private func append(_ character: String) {
        if character == "." {
            guard allowsDecimal, !text.contains(".") else { return }
            text = text.isEmpty ? "0." : text + "."
            return
        }
        if text == "0" {
            text = character
        } else if text.count < 7 {
            if let dot = text.firstIndex(of: "."), text[text.index(after: dot)...].count >= 2 { return }
            text += character
        }
    }

    private func commit() {
        guard let value, range.contains(value) else {
            DonkHaptics.error()
            withAnimation(.default) { shakes += 1 }
            return
        }
        DonkHaptics.success()
        onCommit(value)
    }
}

private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(shakes * .pi * 4), y: 0))
    }
}
