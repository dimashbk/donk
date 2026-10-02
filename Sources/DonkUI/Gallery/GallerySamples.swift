import DonkJSON
import Foundation

enum GallerySamples {
    static let json = """
    {
      "id": 1024,
      "status": "active",
      "score": 98.6,
      "verified": true,
      "deletedAt": null,
      "user": {
        "name": "Ada Lovelace",
        "email": "ada@example.com",
        "roles": ["admin", "editor"],
        "address": {"city": "London", "zip": "NW1 6XE", "geo": {"lat": 51.5237, "lng": -0.1585}}
      },
      "items": [
        {"id": 1, "title": "Analytical Engine", "price": 1843.0, "tags": ["math", "history"]},
        {"id": 2, "title": "Difference Engine", "price": 1822.5, "tags": []},
        {"id": 3, "title": "Note G", "price": 0, "tags": ["algorithm"]}
      ],
      "description": "A deliberately long string value that wraps across several lines so the tree and code views can be checked for wrapping, indentation guides and search highlighting at once.",
      "pagination": {"page": 1, "pageSize": 20, "total": 3, "next": null}
    }
    """

    static let invalidJSON = """
    {
      "name": "Broken payload",
      "count": 3
      "missing": "comma above"
    }
    """

    static let plainText = """
    HTTP/1.1 200 OK
    Content-Type: text/plain; charset=utf-8

    Plain text responses are shown without syntax colors.
    Search still highlights every match and lets you jump between them.
    """

    static let curl = "curl -X POST 'https://api.example.com/v1/orders?expand=items' -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature' -H 'Content-Type: application/json' --data-raw '{\"sku\":\"A-1\",\"quantity\":2}'"

    static let headers: [DonkKeyValue] = [
        DonkKeyValue("Content-Type", "application/json; charset=utf-8"),
        DonkKeyValue("Cache-Control", "no-cache, no-store, must-revalidate"),
        DonkKeyValue("Authorization", "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"),
        DonkKeyValue("X-Request-ID", "6f1c2a9e-4b7d-4f0e-9c1a-2d3e4f5a6b7c"),
        DonkKeyValue("Set-Cookie", "session=abc123; Path=/; HttpOnly; Secure; SameSite=Lax"),
        DonkKeyValue("Set-Cookie", "theme=dark; Path=/; Max-Age=31536000"),
    ]

    static var jsonData: Data {
        Data(json.utf8)
    }

    static let binaryData: Data = {
        var bytes: [UInt8] = [0x0A, 0x07, 0x41, 0x63, 0x63, 0x6F, 0x75, 0x6E, 0x74, 0x10, 0x96, 0x01, 0x1A, 0x03, 0x55, 0x53, 0x44]
        for index in 0..<240 {
            bytes.append(UInt8((index * 37 + 11) % 256))
        }
        return Data(bytes)
    }()

    static func largeValue(items: Int) -> JSONValue {
        let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
        let elements: [JSONValue] = (0..<items).map { index in
            .object([
                JSONMember(key: "id", value: .number("\(index)")),
                JSONMember(key: "name", value: .string("\(names[index % names.count])-\(index)")),
                JSONMember(key: "active", value: .bool(index % 3 != 0)),
                JSONMember(key: "score", value: .number(String(format: "%.2f", Double(index % 97) * 1.37))),
                JSONMember(key: "owner", value: index % 5 == 0 ? .null : .string("user\(index % 40)@example.com")),
                JSONMember(key: "tags", value: .array([.string(names[(index + 1) % names.count]), .string(names[(index + 3) % names.count])])),
                JSONMember(key: "metrics", value: .object([
                    JSONMember(key: "latency", value: .number("\(20 + index % 180)")),
                    JSONMember(key: "errors", value: .number("\(index % 7)")),
                ])),
            ])
        }
        return .object([
            JSONMember(key: "generatedAt", value: .string("2026-10-01T12:00:00Z")),
            JSONMember(key: "count", value: .number("\(items)")),
            JSONMember(key: "records", value: .array(elements)),
        ])
    }

    static func series(seed: Double, base: Double, amplitude: Double, time: TimeInterval, count: Int = 60) -> [Double] {
        let now = time.rounded(.down)
        return (0..<count).map { index in
            let x = now - Double(count - index)
            return base + amplitude * sin(x / 7 + seed) + amplitude * 0.35 * sin(x / 2.3 + seed * 2)
        }
    }
}
