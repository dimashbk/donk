import DonkCore
import Foundation
import ObjectiveC.runtime
import UserNotifications

struct PushSynthesisError: Error, Equatable, CustomStringConvertible {
    var message: String

    var description: String { message }
}

enum PushSynthesizer {
    static var systemDescription: String {
        "iOS " + DonkEnvironment.appInfo.osVersion
    }

    static func unsupportedOutcome(_ error: PushSynthesisError, steps: [PushStep]) -> PushDeliveryOutcome {
        PushDeliveryOutcome(
            status: .failure,
            title: "Unsupported on this iOS",
            lines: [
                PushOutcomeLine("Reason", error.message),
                PushOutcomeLine("System", systemDescription),
                PushOutcomeLine("Use instead", "Banner, or Export to push through simctl"),
            ],
            steps: steps
        )
    }

    static func makePushTrigger() -> UNNotificationTrigger? {
        guard let trigger = decode(UNPushNotificationTrigger.self, values: ["repeats": false]) else { return nil }
        return trigger
    }

    static func makeNotification(request: UNNotificationRequest, date: Date = Date()) -> Result<UNNotification, PushSynthesisError> {
        let primitives: [String: Any] = [
            "date": date as NSDate,
            "sourceIdentifier": Bundle.main.bundleIdentifier ?? "",
        ]
        if let notification = decode(UNNotification.self, values: primitives), canSet(notification, key: "request") {
            notification.setValue(request, forKey: "request")
            if !(currentValue(of: notification, key: "date") is Date) {
                fill(notification, key: "date", value: date as NSDate)
            }
            if isValid(notification, identifier: request.identifier) {
                return .success(notification)
            }
        }
        guard isSafeToArchive(request) else {
            return .failure(PushSynthesisError(message: "UNNotification cannot be synthesized for this content on this iOS version."))
        }
        var values = primitives
        values["request"] = request
        guard let archived = decode(UNNotification.self, values: values), isValid(archived, identifier: request.identifier) else {
            return .failure(PushSynthesisError(message: "UNNotification(coder:) is not supported on this iOS version."))
        }
        return .success(archived)
    }

    static func makeResponse(
        notification: UNNotification,
        actionIdentifier: String = UNNotificationDefaultActionIdentifier,
        userText: String? = nil
    ) -> Result<UNNotificationResponse, PushSynthesisError> {
        var values: [String: Any] = ["actionIdentifier": actionIdentifier]
        if let userText {
            values["userText"] = userText
        }
        let decoded: UNNotificationResponse? = userText == nil
            ? decode(UNNotificationResponse.self, values: values)
            : decode(UNTextInputNotificationResponse.self, values: values)
        guard let response = decoded else {
            return .failure(PushSynthesisError(message: "UNNotificationResponse(coder:) is not supported on this iOS version."))
        }
        guard canSet(response, key: "notification") else {
            return .failure(PushSynthesisError(message: "UNNotificationResponse cannot carry a synthesized notification on this iOS version."))
        }
        response.setValue(notification, forKey: "notification")
        if (currentValue(of: response, key: "actionIdentifier") as? String) != actionIdentifier {
            fill(response, key: "actionIdentifier", value: actionIdentifier)
        }
        if let userText, (currentValue(of: response, key: "userText") as? String) != userText {
            fill(response, key: "userText", value: userText)
        }
        guard
            currentValue(of: response, key: "notification") as? UNNotification === notification,
            (currentValue(of: response, key: "actionIdentifier") as? String) == actionIdentifier
        else {
            return .failure(PushSynthesisError(message: "Could not build a UNNotificationResponse on this iOS version."))
        }
        if let userText, (currentValue(of: response, key: "userText") as? String) != userText {
            return .failure(PushSynthesisError(message: "Could not attach the text input to the response on this iOS version."))
        }
        return .success(response)
    }

    private static func isValid(_ notification: UNNotification, identifier: String) -> Bool {
        (currentValue(of: notification, key: "request") as? UNNotificationRequest)?.identifier == identifier
    }

    private static func isSafeToArchive(_ request: UNNotificationRequest) -> Bool {
        request.content.attachments.isEmpty && !containsNull(request.content.userInfo)
    }

    private static func containsNull(_ value: Any) -> Bool {
        switch value {
        case is NSNull:
            return true
        case let dictionary as [AnyHashable: Any]:
            return dictionary.values.contains { containsNull($0) }
        case let array as [Any]:
            return array.contains { containsNull($0) }
        default:
            return false
        }
    }

    // MARK: - Coder

    private static func decode<T: NSObject & NSCoding>(_ type: T.Type, values: [String: Any]) -> T? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        for (key, value) in values {
            switch value {
            case let flag as Bool:
                archiver.encode(flag, forKey: key)
            default:
                archiver.encode(value as AnyObject, forKey: key)
            }
        }
        archiver.finishEncoding()
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return type.init(coder: unarchiver)
    }

    private static func currentValue(of object: NSObject, key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    private static func fill(_ object: NSObject, key: String, value: Any) {
        guard canSet(object, key: key) else { return }
        object.setValue(value, forKey: key)
    }

    private static func canSet(_ object: NSObject, key: String) -> Bool {
        let capitalized = key.prefix(1).uppercased() + key.dropFirst()
        if object.responds(to: NSSelectorFromString("set\(capitalized):")) {
            return true
        }
        guard type(of: object).accessInstanceVariablesDirectly else { return false }
        var cls: AnyClass? = object_getClass(object)
        while let current = cls {
            for name in ["_\(key)", "_is\(capitalized)", key, "is\(capitalized)"]
            where class_getInstanceVariable(current, name) != nil {
                return true
            }
            cls = class_getSuperclass(current)
        }
        return false
    }
}
