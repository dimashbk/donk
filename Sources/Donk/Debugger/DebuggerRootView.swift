import DonkCrash
import DonkInspector
import DonkNetworkUI
import DonkPerformance
import DonkPush
import DonkStorage
import DonkUI
import SwiftUI

struct DebuggerRootView: View {
    @ObservedObject var router: DebuggerRouter
    let home: HomeModel

    var body: some View {
        DonkNavigationContainer {
            HomeView(model: home, router: router)
        }
        .donkTheme()
    }
}

// MARK: - Destinations

enum DebuggerDestination {
    @MainActor @ViewBuilder
    static func view(for tool: DonkTool) -> some View {
        switch tool {
        case .network:
            DonkNetworkUI.makeRootView()
        case .rules:
            DonkNetworkUI.makeRulesView()
        case .performance:
            DonkPerformance.makeRootView()
        case .inspector:
            DonkInspector.makeRootView()
        case .push:
            DonkPush.makeRootView()
        case .storage:
            DonkStorage.makeRootView()
        case .crashes:
            DonkCrash.makeRootView()
        case .settings:
            SettingsView()
        }
    }
}
