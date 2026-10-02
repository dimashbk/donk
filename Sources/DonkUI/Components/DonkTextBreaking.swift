import Foundation

public enum DonkTextBreaking {
    public static let longRunThreshold = 24

    public static func breakable<S: StringProtocol>(_ text: S) -> String {
        guard text.utf8.count > longRunThreshold else { return String(text) }
        var output = ""
        output.reserveCapacity(text.utf8.count + text.utf8.count / 2)
        var run: [Character] = []
        run.reserveCapacity(64)

        func flush() {
            if run.count > longRunThreshold {
                for character in run {
                    output.append(character)
                    output.append("\u{200B}")
                }
            } else {
                output.append(contentsOf: run)
            }
            run.removeAll(keepingCapacity: true)
        }

        for character in text {
            if character.isWhitespace {
                flush()
                output.append(character)
            } else {
                run.append(character)
            }
        }
        flush()
        return output
    }

    public static let keySeparators: Set<Character> = ["-", "_", ".", "/", ":"]

    public static func breakableKey<S: StringProtocol>(_ text: S) -> String {
        guard text.contains(where: { keySeparators.contains($0) }) else { return breakable(text) }
        var output = ""
        output.reserveCapacity(text.utf8.count + text.utf8.count / 4)
        var segment = ""

        func flush() {
            output.append(segment.count > longRunThreshold ? breakable(segment) : segment)
            segment.removeAll(keepingCapacity: true)
        }

        for character in text {
            if character.isWhitespace {
                flush()
                output.append(character)
            } else if keySeparators.contains(character) {
                segment.append(character)
                flush()
                output.append("\u{200B}")
            } else {
                segment.append(character)
            }
        }
        flush()
        if output.hasSuffix("\u{200B}") {
            output.removeLast()
        }
        return output
    }
}
