@_exported import DonkJSON
import Combine
import Foundation

public enum DonkEnvironment {
    public static let version = "0.1.0"

    public static let internalRequestKey = "dev.donk.internal-request"

    public static let internalSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        markInternal(configuration)
        return URLSession(configuration: configuration)
    }()

    public static var appInfo: AppInfo { AppInfo.current }

    package static func markInternal(_ configuration: URLSessionConfiguration) {
        internalConfigurations.insert(configuration)
    }

    package static func isInternal(_ configuration: URLSessionConfiguration) -> Bool {
        internalConfigurations.contains(configuration)
    }

    private static let internalConfigurations = WeakIdentitySet<URLSessionConfiguration>()

    // MARK: - Activity

    public static var isActive: Bool { activeFlag.value }

    public static var activation: AnyPublisher<Bool, Never> { activeFlag.publisher }

    package static func setActive(_ isActive: Bool) {
        _ = imageSentinel
        activeFlag.set(isActive)
    }

    private static let activeFlag = DonkFlag(false)

    private static let imageSentinel: AnyClass = DonkCoreImageSentinel.self

    // MARK: - Debugger UI

    public static var isDebuggerVisible: Bool { debuggerVisibleFlag.value }

    public static var debuggerVisibility: AnyPublisher<Bool, Never> { debuggerVisibleFlag.publisher }

    package static func setDebuggerVisible(_ isVisible: Bool) {
        debuggerVisibleFlag.set(isVisible)
    }

    package static var hideDebuggerHandler: (@MainActor () -> Void)? {
        get { hideHandlerBox.value }
        set { hideHandlerBox.value = newValue }
    }

    @MainActor public static func requestHideDebugger() {
        hideDebuggerHandler?()
    }

    private static let debuggerVisibleFlag = DonkFlag(false)

    private static let hideHandlerBox = LockedBox<(@MainActor () -> Void)?>(nil)
}

@objc(DonkCoreImageSentinel)
final class DonkCoreImageSentinel: NSObject {}

// MARK: - AppInfo

public struct AppInfo: Sendable, Equatable {
    public var name: String
    public var bundleID: String
    public var version: String
    public var build: String
    public var osVersion: String
    public var deviceModel: String

    public init(name: String, bundleID: String, version: String, build: String, osVersion: String, deviceModel: String) {
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.osVersion = osVersion
        self.deviceModel = deviceModel
    }

    static let current: AppInfo = {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? ProcessInfo.processInfo.processName
        return AppInfo(
            name: name,
            bundleID: bundle.bundleIdentifier ?? "",
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "",
            osVersion: osVersionString(),
            deviceModel: deviceModelIdentifier()
        )
    }()

    static func osVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var result = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 {
            result += ".\(version.patchVersion)"
        }
        return result
    }

    static func deviceModelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}
