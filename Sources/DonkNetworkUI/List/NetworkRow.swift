import DonkCore
import DonkUI
import SwiftUI

struct NetworkRow: View, Equatable {
    let item: NetworkRowItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            topLine
            Text(DonkTextBreaking.breakable(item.title))
                .font(.subheadline.weight(.medium))
                .foregroundColor(DonkColor.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            bottomLine
        }
        .padding(.vertical, 9)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(item.barTone.color)
                .frame(width: 3.5)
                .padding(.vertical, 8)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var topLine: some View {
        HStack(spacing: 6) {
            MethodBadge(item.method)
            if let initiator = item.initiator {
                HStack(spacing: 3) {
                    Image(systemName: "safari")
                        .font(.caption2.weight(.semibold))
                    Text(initiator)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundColor(DonkColor.web)
                .fixedSize()
            }
            if let origin = item.origin {
                OriginTag(badge: origin)
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(DonkColor.warning)
                    .rotationEffect(.degrees(35))
                    .accessibilityLabel("Pinned")
            }
            Spacer(minLength: 6)
            if item.isPaused {
                TonePill(text: "Paused", tone: .warning, icon: "pause.fill")
            } else {
                StatusPill(item.status, tone: item.statusTone, isLive: item.isLive)
            }
        }
    }

    private var bottomLine: some View {
        HStack(spacing: 6) {
            Text(subtitle)
                .font(.caption)
                .foregroundColor(DonkColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let metrics {
                Text(metrics)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var subtitle: String {
        [item.host ?? "—", item.time].joined(separator: " · ")
    }

    private var metrics: String? {
        let parts = [item.duration, item.size].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct OriginTag: View {
    let badge: OriginBadge

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: badge.icon)
                .font(.caption2.weight(.bold))
                .imageScale(.small)
            Text(badge.title)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
        }
        .foregroundColor(badge.tone.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(badge.tone.softBackground))
        .fixedSize()
    }
}
