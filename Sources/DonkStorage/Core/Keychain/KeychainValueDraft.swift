import Foundation

enum KeychainValueEncoding: String, CaseIterable, Hashable, Sendable {
    case utf8 = "UTF-8"
    case base64 = "Base64"
}

struct KeychainValueDraft: Equatable, Sendable {
    enum ConversionIssue: Error, Equatable {
        case invalidBase64
        case notText

        var message: String {
            switch self {
            case .invalidBase64: return "Fix the base64 text first"
            case .notText: return "The value isn't UTF-8 text"
            }
        }
    }

    var encoding: KeychainValueEncoding
    var text: String

    init(encoding: KeychainValueEncoding, text: String) {
        self.encoding = encoding
        self.text = text
    }

    init(data: Data) {
        if let text = KeychainStore.text(from: data) {
            self.init(encoding: .utf8, text: text)
        } else {
            self.init(encoding: .base64, text: data.base64EncodedString())
        }
    }

    var data: Data? {
        switch encoding {
        case .utf8: return Data(text.utf8)
        case .base64: return DefaultsValues.parseBase64(text)
        }
    }

    func converted(to target: KeychainValueEncoding) -> Result<KeychainValueDraft, ConversionIssue> {
        guard target != encoding else { return .success(self) }
        switch target {
        case .base64:
            return .success(KeychainValueDraft(encoding: .base64, text: Data(text.utf8).base64EncodedString()))
        case .utf8:
            guard let data = DefaultsValues.parseBase64(text) else { return .failure(.invalidBase64) }
            guard let decoded = KeychainStore.text(from: data) else { return .failure(.notText) }
            return .success(KeychainValueDraft(encoding: .utf8, text: decoded))
        }
    }
}
