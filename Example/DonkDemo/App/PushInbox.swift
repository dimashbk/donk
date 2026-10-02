import Donk
import Foundation
import SwiftUI

final class PushInbox: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let date = Date()
        let source: String
        let payload: String
    }

    static let shared = PushInbox()

    @Published private(set) var items: [Item] = []

    func record(source: String, userInfo: [AnyHashable: Any]) {
        let object = userInfo.reduce(into: [String: Any]()) { $0["\($1.key)"] = $1.value }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let item = Item(source: source, payload: String(decoding: data, as: UTF8.self))
        DispatchQueue.main.async {
            self.items.insert(item, at: 0)
        }
    }
}

enum DemoPushTemplates {
    static let all: [PushTemplate] = [
        PushTemplate(
            id: UUID(),
            name: "Payment received",
            payload: #"{"aps":{"alert":{"title":"Payment received","body":"+25 000 ₸ from Aruzhan"},"sound":"default","mutable-content":1},"navigation":"paymentHistory","paymentId":"42","fcm_options":{"image":"https://picsum.photos/seed/donk/600/400"}}"#
        ),
        PushTemplate(
            id: UUID(),
            name: "OTP code",
            payload: #"{"aps":{"alert":{"title":"Confirmation code","body":"Your code: 482913"},"sound":"default"},"message":"Your code: 482913","channelId":"otp"}"#
        ),
        PushTemplate(
            id: UUID(),
            name: "Silent sync",
            payload: #"{"aps":{"content-available":1},"type":"sync","scope":"accounts"}"#
        ),
    ]
}
