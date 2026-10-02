import Donk
import Foundation
import UIKit

enum SampleBodies {
    static let accounts = #"""
    {"accounts":[{"id":"acc_01HV6Q","type":"current","currency":"KZT","balance":{"available":1284500.75,"blocked":12000},"iban":"KZ86125KZT5004100100","isPrimary":true,"limits":{"daily":2000000,"monthly":15000000}},{"id":"acc_01HV6R","type":"savings","currency":"USD","balance":{"available":4210.12,"blocked":0},"iban":"KZ56125USD5004100777","isPrimary":false,"rate":"13.4%"},{"id":"acc_01HV6S","type":"card","currency":"EUR","balance":{"available":310.4,"blocked":22.5},"cardMask":"4400 •••• •••• 1290","isPrimary":false}],"updatedAt":"2026-10-01T09:41:12.418Z","meta":{"requestId":"7f3a9c1e-62d4-4b0f-9a55-1c2e8b7d4f10","cursor":null}}
    """#

    static let transferRequest = #"""
    {"fromAccount":"acc_01HV6Q","toPhone":"+7 701 555 0182","amount":{"value":25000,"currency":"KZT"},"comment":"Dinner 🍜","idempotencyKey":"tr-8c51f0b2"}
    """#

    static let transferResponse = #"""
    {"id":"tr_01HV9K2M3N","status":"accepted","amount":{"value":25000,"currency":"KZT"},"fee":{"value":0,"currency":"KZT"},"recipient":{"name":"Aruzhan S.","bank":"Donk Bank"},"createdAt":"2026-10-01T09:42:03.118Z","receiptUrl":"https://api.donkbank.io/v1/receipts/tr_01HV9K2M3N.pdf"}
    """#

    static let profileUpdate = #"""
    {"displayName":"Dinmukhamed","email":"d@example.com","language":"en","notifications":{"push":true,"email":false,"sms":true}}
    """#

    static let profile = #"""
    {"id":"usr_42","displayName":"Dinmukhamed","email":"d@example.com","phone":"+7 701 *** ** 82","language":"en","kycLevel":"full","createdAt":"2021-03-14T08:00:00Z","avatarUrl":"https://images.donkbank.io/avatars/usr_42.png","notifications":{"push":true,"email":false,"sms":true}}
    """#

    static let validationError = #"""
    {"error":{"code":"VALIDATION_FAILED","message":"Request validation failed","details":[{"field":"amount.value","reason":"must be greater than 0"},{"field":"toPhone","reason":"invalid phone number format"}],"traceId":"5b8e0f62a7c94b12"}}
    """#

    static let unauthorized = #"""
    {"error":{"code":"TOKEN_EXPIRED","message":"Access token expired at 2026-10-01T09:30:00Z","hint":"Refresh the session with /oauth/token"}}
    """#

    static let notFound = #"""
    {"error":{"code":"NOT_FOUND","message":"Card 9999 does not exist or is not linked to this customer"}}
    """#

    static let serverError = #"""
    {"error":{"code":"INTERNAL","message":"Unexpected error while processing payment","traceId":"a1c9e33f0b7d4e21","retryable":false}}
    """#

    static let unavailable = "upstream connect error or disconnect/reset before headers. reset reason: overflow"

    static let featureFlags = #"""
    {"flags":{"newOnboarding":true,"cardControls":true,"cryptoTab":false,"qrPayments":true,"darkIcons":false},"experiment":{"name":"home-v3","variant":"B"},"ttl":300}
    """#

    static let balance = #"""
    {"available":999999.99,"currency":"KZT","asOf":"2026-10-01T09:40:00Z","source":"mock"}
    """#

    static let rates = #"""
    {"base":"KZT","rates":[{"currency":"USD","buy":478.5,"sell":482.1},{"currency":"EUR","buy":521.3,"sell":526.9},{"currency":"RUB","buy":5.12,"sell":5.31}]}
    """#

    static let token = #"""
    {"access_token":"eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c3JfNDIiLCJzY29wZSI6InJlYWQgd3JpdGUiLCJleHAiOjE3OTU5OTk5OTl9.c2lnbmF0dXJlLXBsYWNlaG9sZGVy","token_type":"Bearer","expires_in":3600,"refresh_token":"rt_9c2f4e8a1b7d","scope":"read write"}
    """#

    static let formBody = "grant_type=password&username=dinmukhamed%40example.com&password=%E2%80%A2%E2%80%A2%E2%80%A2%E2%80%A2&scope=read+write&client_id=donk-ios&device_name=iPhone+17+Pro+Max"

    static let statusText = """
    status: operational
    region: kz-almaty-1
    build: 2026.09.30-1842 (a7c91e3)
    uptime: 18d 04h 12m
    queue depth: 12
    db replication lag: 38ms
    """

    static let html = """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Transfer limits</title><link rel="stylesheet" href="/static/app.css"></head>
    <body>
      <h1>Transfer limits</h1>
      <p>Daily limit for card-to-card transfers is 2 000 000 ₸.</p>
      <script src="/static/app.js"></script>
    </body>
    </html>
    """

    static let chatRequest = #"""
    {"conversationId":"conv_77","text":"How do I raise my transfer limit?","locale":"en"}
    """#

    static let chatResponse = #"""
    {"messageId":"msg_9183","conversationId":"conv_77","author":"assistant","text":"Open Settings → Limits and tap Raise limit. You may be asked to confirm with Face ID.","suggestions":["Open limits","Talk to a person"]}
    """#

    static func largeTransactions(count: Int = 5200) -> Data {
        let merchants = ["Green Market", "Corner Shop", "City Taxi", "Bean & Leaf", "SkyLine Air", "TechHub", "QuickEats", "StreamBox", "Book Nook", "Fuel Point"]
        let categories = ["groceries", "transport", "transfer", "coffee", "travel", "electronics", "food", "subscriptions"]
        var text = "{\"items\":["
        text.reserveCapacity(count * 300)
        for index in 0..<count {
            if index > 0 { text += "," }
            let merchant = merchants[index % merchants.count]
            let category = categories[index % categories.count]
            let amount = Double((index * 7919) % 250_000) / 100 + 1
            let day = 1 + index % 28
            text += "{\"id\":\"txn_\(String(format: "%06d", index))\",\"merchant\":\"\(merchant)\",\"category\":\"\(category)\",\"amount\":{\"value\":\(String(format: "%.2f", amount)),\"currency\":\"KZT\"},\"status\":\"\(index % 17 == 0 ? "pending" : "settled")\",\"bookedAt\":\"2026-09-\(String(format: "%02d", day))T\(String(format: "%02d", index % 24)):\(String(format: "%02d", index % 60)):00Z\",\"tags\":[\"\(category)\",\"card\"],\"location\":{\"city\":\"Almaty\",\"lat\":43.2\(index % 10),\"lon\":76.9\(index % 7)}}"
        }
        text += "],\"total\":\(count),\"nextCursor\":\"c_\(count)\"}"
        return Data(text.utf8)
    }

    static func largeLog(lines: Int = 26_000) -> Data {
        var text = ""
        text.reserveCapacity(lines * 100)
        for index in 0..<lines {
            text += "2026-10-01T09:\(String(format: "%02d", index % 60)):\(String(format: "%02d", (index * 7) % 60)).\(String(format: "%03d", index % 1000))Z INFO  [sync-worker-\(index % 8)] processed batch \(index) in \(index % 97) ms\n"
        }
        return Data(text.utf8)
    }

    static func binary(size: Int = 6 * 1024) -> Data {
        var generator = SeededGenerator(seed: 42)
        var bytes = [UInt8](repeating: 0, count: size)
        let header: [UInt8] = [0x44, 0x4F, 0x4E, 0x4B, 0x01, 0x00, 0x02, 0x00]
        for index in 0..<size {
            bytes[index] = index < header.count ? header[index] : UInt8.random(in: 0...255, using: &generator)
        }
        return Data(bytes)
    }

    @MainActor
    static func avatarPNG() -> Data {
        let size = CGSize(width: 320, height: 320)
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        let image = renderer.image { context in
            let colors = [UIColor(red: 0.43, green: 0.36, blue: 0.99, alpha: 1).cgColor, UIColor(red: 0.18, green: 0.83, blue: 0.75, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.22).setFill()
            UIBezierPath(ovalIn: CGRect(x: 40, y: 40, width: 240, height: 240)).fill()
            let text = "DK" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 110, weight: .heavy),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
        return image.pngData() ?? Data()
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
