import DonkUI
import SwiftUI

// MARK: - Headline

struct MetricHeadline: View {
    let value: String
    let unit: String?
    let tone: DonkTone
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: unit == "%" ? 1 : 4) {
                Text(value)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundColor(tone == .neutral ? DonkColor.textSecondary : tone.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(DonkFont.rounded(.headline, weight: .semibold))
                        .foregroundColor(DonkColor.textSecondary)
                }
            }
            if let caption {
                Text(caption)
                    .font(DonkFont.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Secondary metric

struct SecondaryMetric: View {
    let title: String
    let value: String
    let tone: DonkTone

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(DonkFont.metricSmall)
                .foregroundColor(tone == .neutral ? DonkColor.textPrimary : tone.color)
                .lineLimit(1)
            Text(title)
                .font(DonkFont.caption2)
                .foregroundColor(DonkColor.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Usage bar

struct UsageBar: View {
    let fraction: Double
    let tone: DonkTone

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DonkColor.fill)
                Capsule()
                    .fill(tone.color)
                    .frame(width: max(fraction > 0 ? 3 : 0, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

// MARK: - Inline empty state

struct InlineEmptyState: View {
    let icon: String
    let title: String
    let message: String?

    var body: some View {
        HStack(alignment: .top, spacing: DonkSpacing.m) {
            DonkIconBadge(icon, tone: .neutral, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DonkFont.rowTitle)
                    .foregroundColor(DonkColor.textPrimary)
                if let message {
                    Text(message)
                        .font(DonkFont.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DonkSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Info disclosure

struct InfoDisclosure: View {
    let text: String
    @Binding var isExpanded: Bool

    var body: some View {
        if isExpanded {
            HStack(alignment: .top, spacing: DonkSpacing.s) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(DonkColor.info)
                    .font(.footnote)
                Text(text)
                    .font(DonkFont.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DonkSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous)
                    .fill(DonkTone.info.softBackground)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

struct InfoButton: View {
    @Binding var isExpanded: Bool
    let label: String

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                isExpanded.toggle()
            }
            DonkHaptics.selection()
        } label: {
            Image(systemName: isExpanded ? "info.circle.fill" : "info.circle")
                .font(.body)
        }
        .buttonStyle(.plain)
        .foregroundColor(DonkColor.accent)
        .accessibilityLabel(label)
    }
}

// MARK: - Event presentation

struct LazyChart<Content: View>: View {
    let isReady: Bool
    let height: CGFloat
    let content: () -> Content

    init(isReady: Bool, height: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.isReady = isReady
        self.height = height
        self.content = content
    }

    var body: some View {
        Group {
            if isReady {
                content()
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: DonkRadius.small, style: .continuous)
                    .fill(DonkColor.textTertiary.opacity(0.08))
                    .accessibilityHidden(true)
            }
        }
        .frame(height: height)
    }
}

struct DonkScreenActivity: ViewModifier {
    let monitor: PerformanceMonitor

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.donkScreenDidAppear() }
            .onDisappear { monitor.donkScreenDidDisappear() }
    }
}

extension View {
    func tracksDonkScreen(_ monitor: PerformanceMonitor = .shared) -> some View {
        modifier(DonkScreenActivity(monitor: monitor))
    }
}

extension PerformanceEvent {
    var icon: String {
        switch kind {
        case .hang: return "hourglass"
        case .memoryWarning: return "exclamationmark.triangle.fill"
        case .thermal: return "thermometer"
        case let .lowPowerMode(enabled): return enabled ? "battery.25" : "battery.100"
        case let .alert(alertKind): return alertKind.icon
        }
    }

    var subtitle: String {
        var parts = [DonkFormat.time(date)]
        switch kind {
        case .hang:
            parts.append(backtrace == nil ? "No stack (under 1 s)" : "Stack captured")
        case .alert:
            parts.append("Alert")
        default:
            if let detail { parts.append(detail) }
        }
        return parts.joined(separator: " · ")
    }

    var copyText: String {
        var text = "\(DonkFormat.dateTime(date))  \(title)"
        if let detail { text += " (\(detail))" }
        if let backtrace { text += "\n\n" + backtrace.text }
        return text
    }
}

extension PerformanceSeverity {
    var title: String {
        switch self {
        case .info: return "Info"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

extension ProcessInfo.ThermalState {
    var tone: DonkTone {
        switch self {
        case .nominal: return .success
        case .fair: return .info
        case .serious: return .warning
        case .critical: return .error
        @unknown default: return .neutral
        }
    }
}
