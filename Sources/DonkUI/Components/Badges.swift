import SwiftUI

// MARK: - Method badge

public struct MethodBadge: View {
    private let method: String
    @Environment(\.colorScheme) private var colorScheme

    public init(_ method: String) {
        self.method = method
    }

    public var body: some View {
        let color = DonkColor.method(method)
        Text(method.uppercased())
            .font(DonkFont.badge)
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: DonkRadius.badge, style: .continuous)
                    .fill(color.opacity(colorScheme == .dark ? 0.2 : 0.12))
            )
            .fixedSize()
            .accessibilityLabel("\(method) method")
    }
}

// MARK: - Tone pill

public struct TonePill: View {
    private let text: String
    private let tone: DonkTone
    private let icon: String?

    public init(text: String, tone: DonkTone = .neutral, icon: String? = nil) {
        self.text = text
        self.tone = tone
        self.icon = icon
    }

    public init(_ text: String, tone: DonkTone = .neutral, icon: String? = nil) {
        self.init(text: text, tone: tone, icon: icon)
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundColor(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tone.softBackground))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status pill

public struct StatusPill: View {
    private let label: String
    private let tone: DonkTone
    private let isLive: Bool

    public init(_ label: String, tone: DonkTone, isLive: Bool = false) {
        self.label = label
        self.tone = tone
        self.isLive = isLive
    }

    public init(code: Int, isLive: Bool = false) {
        self.label = code > 0 ? "\(code)" : "…"
        self.tone = code > 0 ? DonkTone.httpStatus(code) : .neutral
        self.isLive = isLive || code <= 0
    }

    public var body: some View {
        HStack(spacing: 5) {
            if isLive {
                LiveDot(tone: tone, size: 6)
            }
            Text(label)
                .font(DonkFont.rounded(.caption, weight: .bold).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundColor(tone.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tone.softBackground))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status \(label)")
    }
}

// MARK: - Count badge

public struct CountBadge: View {
    private let count: Int
    private let tone: DonkTone
    private let filled: Bool

    public init(_ count: Int, tone: DonkTone = .error, filled: Bool = true) {
        self.count = count
        self.tone = tone
        self.filled = filled
    }

    public var body: some View {
        Text(DonkFormat.compact(count))
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundColor(filled ? .white : tone.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 18)
            .background(Capsule().fill(filled ? tone.color : tone.softBackground))
            .fixedSize()
            .accessibilityLabel("\(count)")
    }
}

// MARK: - Live dot

public struct LiveDot: View {
    private let tone: DonkTone
    private let size: CGFloat
    private let isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tone: DonkTone = .info, size: CGFloat = 8, isAnimating: Bool = true) {
        self.tone = tone
        self.size = size
        self.isAnimating = isAnimating
    }

    public var body: some View {
        Group {
            if isAnimating && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let period = 1.4
                    let raw = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    dot(phase: 1 - pow(1 - raw, 2))
                }
            } else {
                dot(phase: nil)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func dot(phase: Double?) -> some View {
        ZStack {
            if let phase {
                Circle()
                    .fill(tone.color.opacity(0.5 * (1 - phase)))
                    .scaleEffect(1 + 1.5 * phase)
            }
            Circle()
                .fill(tone.color)
        }
        .frame(width: size, height: size)
    }
}
