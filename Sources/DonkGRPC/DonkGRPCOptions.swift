import DonkCore
import Foundation
import SwiftProtobuf

public struct DonkGRPCOptions: Sendable {
    public var preserveProtoFieldNames: Bool
    public var alwaysPrintEnumsAsInts: Bool
    public var anyTypeRegistry: [any SwiftProtobuf.Message.Type]
    public var isRulesEnabled: Bool
    public var maxRenderedMessageSize: Int
    public var maxRawMessageSize: Int
    public var maxRenderBacklogMessages: Int
    public var maxRenderBacklogBytes: Int
    public var bypassHosts: [String]
    public var store: NetworkStore
    public var ruleStore: RuleStore
    public var breakpointCenter: BreakpointCenter
    public var settingsStore: NetworkSettingsStore?
    var isEnvironmentActive: @Sendable () -> Bool = { DonkEnvironment.isActive }

    public init(
        preserveProtoFieldNames: Bool = false,
        alwaysPrintEnumsAsInts: Bool = false,
        anyTypeRegistry: [any SwiftProtobuf.Message.Type] = [],
        isRulesEnabled: Bool = true,
        maxRenderedMessageSize: Int = 1024 * 1024,
        maxRawMessageSize: Int = 64 * 1024,
        maxRenderBacklogMessages: Int = 256,
        maxRenderBacklogBytes: Int = 4 * 1024 * 1024,
        bypassHosts: [String] = [],
        store: NetworkStore = .shared,
        ruleStore: RuleStore = .shared,
        breakpointCenter: BreakpointCenter = .shared,
        settingsStore: NetworkSettingsStore? = .shared
    ) {
        self.preserveProtoFieldNames = preserveProtoFieldNames
        self.alwaysPrintEnumsAsInts = alwaysPrintEnumsAsInts
        self.anyTypeRegistry = anyTypeRegistry
        self.isRulesEnabled = isRulesEnabled
        self.maxRenderedMessageSize = maxRenderedMessageSize
        self.maxRawMessageSize = maxRawMessageSize
        self.maxRenderBacklogMessages = maxRenderBacklogMessages
        self.maxRenderBacklogBytes = maxRenderBacklogBytes
        self.bypassHosts = bypassHosts
        self.store = store
        self.ruleStore = ruleStore
        self.breakpointCenter = breakpointCenter
        self.settingsStore = settingsStore
    }

    public var jsonEncodingOptions: JSONEncodingOptions {
        var options = JSONEncodingOptions()
        options.preserveProtoFieldNames = preserveProtoFieldNames
        options.alwaysPrintEnumsAsInts = alwaysPrintEnumsAsInts
        return options
    }

    var effectiveBypassHosts: [String] {
        (settingsStore?.settings.bypassHosts ?? []) + bypassHosts
    }
}
