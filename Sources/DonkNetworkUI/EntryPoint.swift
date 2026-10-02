import DonkCore
import DonkUI
import SwiftUI

public enum DonkNetworkUI {
    @MainActor public static func makeRootView() -> AnyView {
        AnyView(NetworkListView().donkTheme())
    }

    @MainActor public static func makeBreakpointView(_ exchange: PausedExchange) -> AnyView {
        AnyView(BreakpointView(exchange: exchange).donkTheme())
    }

    @MainActor public static func makeDetailView(entryID: UUID) -> AnyView {
        AnyView(EntryDetailView(id: entryID).donkTheme())
    }

    @MainActor public static func makeRulesView() -> AnyView {
        AnyView(RulesListView().donkTheme())
    }
}
