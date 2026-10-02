import Darwin
import DonkCore
import Foundation
import UIKit

@MainActor
enum AccessibilityActivation {
    private struct Marker: Codable {
        var enabledAt: Date
    }

    static let markerName = "inspector-accessibility-marker.json"

    private static var previousState: Bool?
    private static var didRecover = false

    #if DEBUG || DONK_PRIVATE_API
    private typealias Getter = @convention(c) () -> UInt8
    private typealias Setter = @convention(c) (UInt8) -> Void

    private struct Symbols {
        let get: Getter
        let set: Setter
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let getter = dlsym(handle, "_AXSApplicationAccessibilityEnabled"),
              let setter = dlsym(handle, "_AXSApplicationAccessibilitySetEnabled") else { return nil }
        return Symbols(get: unsafeBitCast(getter, to: Getter.self), set: unsafeBitCast(setter, to: Setter.self))
    }()

    static let isCompiledIn = true

    static var isAvailable: Bool {
        symbols != nil
    }
    #else
    static let isCompiledIn = false

    static var isAvailable: Bool {
        false
    }
    #endif

    static var markerDirectory: URL {
        DonkPersistence.directory
    }

    static var hasMarker: Bool {
        FileManager.default.fileExists(atPath: markerDirectory.appendingPathComponent(markerName).path)
    }

    static func activate() {
        recoverIfNeeded()
        #if DEBUG || DONK_PRIVATE_API
        guard previousState == nil, let symbols else { return }
        let wasEnabled = symbols.get() != 0
        previousState = wasEnabled
        if !wasEnabled {
            DonkPersistence.save(Marker(enabledAt: Date()), to: markerName, in: markerDirectory)
            symbols.set(1)
        }
        #endif
    }

    static func restore() {
        #if DEBUG || DONK_PRIVATE_API
        guard let wasEnabled = previousState, let symbols else { return }
        previousState = nil
        if !wasEnabled {
            symbols.set(0)
            DonkPersistence.remove(markerName, in: markerDirectory)
        }
        #endif
    }

    static func recoverIfNeeded() {
        guard !didRecover else { return }
        didRecover = true
        guard previousState == nil, hasMarker else { return }
        #if DEBUG || DONK_PRIVATE_API
        if let symbols, symbols.get() != 0, !isAssistiveTechnologyRunning {
            symbols.set(0)
        }
        #endif
        DonkPersistence.remove(markerName, in: markerDirectory)
    }

    private static var isAssistiveTechnologyRunning: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }
}
