import DonkCore
import Foundation
import UIKit

struct RemoteDevice: Equatable, Sendable {
    var name: String
    var isSimulator: Bool
    var simulatorUDID: String?

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> RemoteDevice {
        let udid = environment["SIMULATOR_UDID"].flatMap { $0.isEmpty ? nil : $0 }
        var name = environment["SIMULATOR_DEVICE_NAME"].flatMap { $0.isEmpty ? nil : $0 }
        if name == nil, Thread.isMainThread {
            name = MainActor.assumeIsolated { UIDevice.current.name }
        }
        return RemoteDevice(
            name: name ?? DonkEnvironment.appInfo.deviceModel,
            isSimulator: isSimulatorBuild || udid != nil,
            simulatorUDID: udid
        )
    }

    private static var isSimulatorBuild: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    var json: JSONValue {
        var object = RemoteObject()
        object.set("name", name)
        object.set("isSimulator", isSimulator)
        object.setNonEmpty("simulatorUDID", simulatorUDID)
        return object.value
    }
}

struct RemoteIdentity: Equatable, Sendable {
    static let protocolVersion = 1

    var session: UUID
    var donkVersion: String
    var app: AppInfo
    var device: RemoteDevice

    static func current(session: UUID = UUID()) -> RemoteIdentity {
        RemoteIdentity(session: session, donkVersion: DonkEnvironment.version, app: DonkEnvironment.appInfo, device: .current())
    }

    var appJSON: JSONValue {
        var object = RemoteObject()
        object.set("name", app.name)
        object.set("bundleID", app.bundleID)
        object.set("version", app.version)
        object.set("build", app.build)
        object.set("osVersion", app.osVersion)
        object.set("deviceModel", app.deviceModel)
        return object.value
    }

    func hello(hasCrashes: Bool, hasForegroundScene: Bool) -> String {
        var capabilities: [JSONValue] = [.string("network")]
        if hasCrashes { capabilities.append(.string("crashes")) }
        if hasForegroundScene { capabilities.append(.string("ui")) }
        var params = RemoteObject()
        params.set("protocol", Self.protocolVersion)
        params.set("session", session.uuidString)
        params.set("donkVersion", donkVersion)
        params.set("app", appJSON)
        params.set("device", device.json)
        params.set("capabilities", .array(capabilities))
        return RemoteFrame.notification("hello", params: params.value)
    }
}

enum ProcessLaunch {
    static let date: Date = startDate() ?? Date()

    private static func startDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
