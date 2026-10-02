import DonkUI
import SwiftUI

struct InspectorRootView: View {
    @ObservedObject private var controller = InspectorController.shared
    @ObservedObject private var settings = InspectorSettingsStore.shared

    var body: some View {
        DonkScrollContainer {
            if let mode = controller.mode {
                activeBanner(mode)
            }
            DonkSectionHeader("Tools", icon: "wrench.and.screwdriver")
                .padding(.horizontal, 4)
            ForEach(InspectorMode.allCases, id: \.self) { mode in
                ModeCard(mode: mode, isActive: controller.mode == mode)
            }
            DonkSectionHeader("Settings", icon: "slider.horizontal.3")
                .padding(.horizontal, 4)
                .padding(.top, DonkSpacing.s)
            GeneralSettingsCard(settings: settings)
            FramesSettingsCard(settings: settings)
            GridSettingsCard(settings: settings)
            RecentColorsCard(settings: settings)
            limitationsCard
        }
        .donkNavigationTitle("Inspector")
    }

    private func activeBanner(_ mode: InspectorMode) -> some View {
        HStack(spacing: 12) {
            LiveDot(tone: mode.tone)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(mode.shortTitle) is active")
                    .font(DonkFont.rounded(.subheadline, weight: .semibold))
                Text("The overlay sits above the app. Close it from the toolbar or here.")
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Stop") {
                DonkHaptics.light()
                DonkInspector.stop()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(DonkColor.error)
        }
        .padding(DonkSpacing.l)
        .background(
            RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)
                .fill(mode.tone.softBackground)
        )
    }

    private var limitationsCard: some View {
        DonkCard(title: "Good to know", icon: "info.circle", tone: .neutral) {
            VStack(alignment: .leading, spacing: 8) {
                bullet("SwiftUI views aren't UIViews. Select mode offers SwiftUI elements from the accessibility tree, which is partial: no fonts, colors or paddings.")
                bullet("The eyedropper reads a snapshot of the app windows in sRGB. Secure text, DRM-protected video and Metal or camera layers may sample as black.")
                bullet("Frames and Grid let touches through, so you can keep using the app. Select and Eyedropper capture touches until you switch modes.")
                bullet("The inspector only draws in its own overlay window and never changes the app's views.")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(DonkColor.textTertiary)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(text)
                .font(.footnote)
                .foregroundColor(DonkColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Mode card

private struct ModeCard: View {
    let mode: InspectorMode
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.m) {
            HStack(alignment: .top, spacing: DonkSpacing.m) {
                DonkIconBadge(mode.icon, tone: mode.tone, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(DonkFont.headline)
                            .foregroundColor(DonkColor.textPrimary)
                        if isActive {
                            TonePill(text: "Active", tone: mode.tone)
                        }
                    }
                    Text(mode.summary)
                        .font(.subheadline)
                        .foregroundColor(DonkColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                if isActive {
                    Button {
                        DonkHaptics.light()
                        DonkInspector.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(mode.tone.color)
                } else {
                    Button {
                        DonkHaptics.light()
                        DonkInspector.start(mode)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(mode.tone.color)
                }
            }
        }
        .padding(DonkSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)
                .fill(DonkColor.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)
                .strokeBorder(isActive ? mode.tone.color.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .accessibilityElement(children: .contain)
    }
}
