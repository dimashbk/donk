import Foundation

public struct PushRecord: Codable, Sendable, Identifiable, Equatable {
    public enum Path: String, Codable, Sendable, CaseIterable {
        case foreground
        case tap
        case silent

        public var title: String {
            switch self {
            case .foreground: return "Foreground"
            case .tap: return "Tap"
            case .silent: return "Silent"
            }
        }

        public var callbackName: String {
            switch self {
            case .foreground: return "userNotificationCenter(_:willPresent:withCompletionHandler:)"
            case .tap: return "userNotificationCenter(_:didReceive:withCompletionHandler:)"
            case .silent: return "application(_:didReceiveRemoteNotification:fetchCompletionHandler:)"
            }
        }
    }

    public var id: UUID
    public var date: Date
    public var path: Path
    public var payload: String
    public var isSimulated: Bool
    public var actionIdentifier: String?
    public var requestIdentifier: String?
    public var userText: String?
    public var categoryIdentifier: String?
    public var appResponse: String?
    public var responseTime: TimeInterval?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        path: Path,
        payload: String,
        isSimulated: Bool,
        actionIdentifier: String? = nil,
        requestIdentifier: String? = nil,
        userText: String? = nil,
        categoryIdentifier: String? = nil,
        appResponse: String? = nil,
        responseTime: TimeInterval? = nil
    ) {
        self.id = id
        self.date = date
        self.path = path
        self.payload = payload
        self.isSimulated = isSimulated
        self.actionIdentifier = actionIdentifier
        self.requestIdentifier = requestIdentifier
        self.userText = userText
        self.categoryIdentifier = categoryIdentifier
        self.appResponse = appResponse
        self.responseTime = responseTime
    }
}
