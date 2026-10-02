import DonkCore
import DonkUI
import SwiftUI

public struct StorageConfiguration: Sendable {
    public var appGroupIdentifiers: [String] = []
    public var userDefaultsSuites: [String] = []

    public init() {}
}

public enum DonkStorage {
    public static func configure(_ configuration: StorageConfiguration) {
        StorageEnvironment.shared.configuration = configuration
    }

    @MainActor public static func makeRootView() -> AnyView {
        AnyView(StorageRootView())
    }
}
