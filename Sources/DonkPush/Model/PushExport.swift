import DonkCore
import Foundation

enum PushAPNsExport {
    static let targetBundleKey = "Simulator Target Bundle"
    static let fileName = "payload.apns"

    static func fileValue(payload: JSONValue, bundleID: String) -> JSONValue {
        guard case var .object(members) = payload else { return payload }
        members.removeAll { $0.key == targetBundleKey }
        members.append(JSONMember(key: targetBundleKey, value: .string(bundleID)))
        return .object(members)
    }

    static func fileContents(payload: JSONValue, bundleID: String) -> String {
        fileValue(payload: payload, bundleID: bundleID).prettyPrinted() + "\n"
    }

    static func fileContents(payload: JSONValue, bundleID: String?) -> String {
        guard let bundleID else {
            guard case var .object(members) = payload else { return payload.prettyPrinted() + "\n" }
            members.removeAll { $0.key == targetBundleKey }
            return JSONValue.object(members).prettyPrinted() + "\n"
        }
        return fileContents(payload: payload, bundleID: bundleID)
    }

    static func command(bundleID: String, fileName: String = fileName) -> String {
        "xcrun simctl push booted \(bundleID) \(fileName)"
    }
}

enum PushBuiltInTemplates {
    static let all: [PushTemplate] = [
        template("0E6B53C2-9D7F-4C61-9E4C-6B1F1A1D0001", "Alert", """
        {
          "aps": {
            "alert": {
              "title": "Order shipped",
              "subtitle": "Arrives tomorrow",
              "body": "Your order #1024 is on its way."
            },
            "sound": "default",
            "badge": 1,
            "thread-id": "orders"
          },
          "type": "order",
          "orderId": "1024"
        }
        """),
        template("0E6B53C2-9D7F-4C61-9E4C-6B1F1A1D0002", "Alert + image", """
        {
          "aps": {
            "alert": {
              "title": "New photo",
              "body": "Aruzhan shared a photo with you."
            },
            "sound": "default",
            "mutable-content": 1
          },
          "fcm_options": {
            "image": "https://picsum.photos/seed/donk-push/800/600"
          },
          "type": "photo"
        }
        """),
        template("0E6B53C2-9D7F-4C61-9E4C-6B1F1A1D0003", "Silent / background", """
        {
          "aps": {
            "content-available": 1
          },
          "type": "sync",
          "scope": "inbox"
        }
        """),
        template("0E6B53C2-9D7F-4C61-9E4C-6B1F1A1D0004", "Actionable", """
        {
          "aps": {
            "alert": {
              "title": "Aruzhan",
              "body": "Are we still on for lunch?"
            },
            "sound": "default",
            "category": "DONK_ACTIONABLE",
            "thread-id": "chat-42"
          },
          "type": "message",
          "chatId": "42"
        }
        """),
        template("0E6B53C2-9D7F-4C61-9E4C-6B1F1A1D0005", "Time-sensitive", """
        {
          "aps": {
            "alert": {
              "title": "Sign-in attempt",
              "body": "Was this you? Confirm within 5 minutes."
            },
            "sound": "default",
            "interruption-level": "time-sensitive",
            "relevance-score": 1
          },
          "type": "security"
        }
        """),
        template("0E6B53C2-9D7F-4C61-9E4C-6B1F1A1D0006", "Badge only", """
        {
          "aps": {
            "badge": 7
          }
        }
        """),
    ]

    private static func template(_ id: String, _ name: String, _ payload: String) -> PushTemplate {
        PushTemplate(id: UUID(uuidString: id) ?? UUID(), name: name, payload: payload)
    }
}
