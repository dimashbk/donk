import DonkCore
import DonkUI
import SwiftUI

struct PushRootView: View {
    @StateObject private var model = PushRootModel()

    var body: some View {
        VStack(spacing: 0) {
            SegmentedTabs(
                selection: $model.tab,
                tabs: PushTab.allCases,
                title: { $0.rawValue },
                icon: { $0.icon },
                badge: { tab in
                    tab == .history && model.unseenCount > 0 ? model.unseenCount : nil
                }
            )
            .padding(.horizontal, DonkSpacing.screen)
            .padding(.top, DonkSpacing.s)
            .padding(.bottom, DonkSpacing.xs)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .donkScreenBackground()
        .donkNavigationTitle("Push Notifications")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if PushHooks.shared.isRecording {
                    HStack(spacing: 5) {
                        LiveDot(tone: .success, size: 7)
                        Text("Recording")
                            .font(DonkFont.caption)
                            .foregroundColor(DonkColor.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .compose:
            PushComposerView(model: model.composer, device: model.device, templates: model.templates)
        case .history:
            PushHistoryView(model: model.history) { record in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    model.open(payload: record.payload, name: "Replay · \(record.path.title)")
                }
                DonkToast.show("Loaded in composer", icon: "arrow.uturn.backward", tone: .info)
            }
        case .templates:
            PushTemplatesView(model: model.templates) { template in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    model.open(payload: template.payload, name: template.name)
                }
                DonkToast.show("Loaded “\(template.name)”", icon: "doc.on.doc", tone: .info)
            }
        }
    }
}
