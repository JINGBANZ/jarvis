import Foundation

/// Reads the `speak` arguments as far as the provider has streamed them. A pure function of the
/// text so far, so every prefix of one reply yields the same snapshot whatever the chunking, and
/// an escape split at the end is simply not shown yet. See wiki/architecture.md#latency.
public enum SpeakArgumentsScanner {
    /// Nil when nothing may be shown early: `lines` opened with a quote instead of a bracket, the
    /// double-encoded form the runner's schema re-ask handles once the reply completes.
    public static func progress(in arguments: String) -> BrainReplyProgress? {
        var scanner = Scanner(Array(arguments.unicodeScalars))
        return scanner.run()
    }

    private struct Scanner {
        private let text: [Unicode.Scalar]
        private var index = 0
        private var closedLines: [String] = []
        private var openLine: String?
        private var linesComplete = false
        private var detail: String?

        init(_ text: [Unicode.Scalar]) {
            self.text = text
        }

        private var snapshot: BrainReplyProgress {
            BrainReplyProgress(closedLines: closedLines, openLine: openLine,
                               linesComplete: linesComplete, detailMarkdown: detail)
        }

        /// The top-level object, key by key; any key but the two shown is skipped unparsed.
        mutating func run() -> BrainReplyProgress? {
            skipWhitespace()
            guard consume("{") else { return snapshot }
            while true {
                skipWhitespace()
                guard index < text.count, !consume("}") else { return snapshot }
                if consume(",") { continue }
                guard text[index] == "\"" else { return snapshot }
                let key = string()
                guard key.complete else { return snapshot }
                skipWhitespace()
                guard consume(":") else { return snapshot }
                skipWhitespace()
                guard index < text.count else { return snapshot }
                switch key.value {
                case "lines":
                    if text[index] == "\"" { return nil }
                    guard consume("[") else {
                        guard skipValue() else { return snapshot }
                        continue
                    }
                    guard lines() else { return snapshot }
                case "detail":
                    if text[index] == "\"" {
                        let value = string()
                        detail = value.value
                        guard value.complete else { return snapshot }
                    } else {
                        guard skipValue() else { return snapshot }
                    }
                default:
                    guard skipValue() else { return snapshot }
                }
            }
        }

        /// After the opening bracket. False while the array is still open.
        private mutating func lines() -> Bool {
            while true {
                skipWhitespace()
                guard index < text.count else { return false }
                if consume("]") {
                    linesComplete = true
                    return true
                }
                if consume(",") { continue }
                guard text[index] == "\"" else {
                    guard skipValue() else { return false }
                    continue
                }
                let line = string()
                guard line.complete else {
                    openLine = line.value
                    return false
                }
                openLine = nil
                if !line.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    closedLines.append(line.value)
                }
            }
        }

        /// The string opening at `index`, escapes decoded as they close. Incomplete at the end of
        /// the text; an escape cut there is held back whole.
        private mutating func string() -> (value: String, complete: Bool) {
            index += 1
            var value = String.UnicodeScalarView()
            while index < text.count {
                let scalar = text[index]
                if scalar == "\"" {
                    index += 1
                    return (String(value), true)
                }
                if scalar != "\\" {
                    value.append(scalar)
                    index += 1
                    continue
                }
                guard let (decoded, length) = escape(at: index) else { return (String(value), false) }
                value.append(contentsOf: decoded)
                index += length
            }
            return (String(value), false)
        }

        /// The escape at `start` and its length in scalars; nil while it is still incomplete.
        private func escape(at start: Int) -> (String.UnicodeScalarView, Int)? {
            guard start + 1 < text.count else { return nil }
            var decoded = String.UnicodeScalarView()
            switch text[start + 1] {
            case "\"": decoded.append("\"")
            case "\\": decoded.append("\\")
            case "/": decoded.append("/")
            case "b": decoded.append("\u{8}")
            case "f": decoded.append("\u{C}")
            case "n": decoded.append("\n")
            case "r": decoded.append("\r")
            case "t": decoded.append("\t")
            case "u":
                guard let unit = hex(at: start + 2) else { return nil }
                guard (0xD800...0xDBFF).contains(unit) else {
                    decoded.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
                    return (decoded, 6)
                }
                // A high surrogate waits for its pair, which may still be on the wire.
                let next = start + 6
                guard next + 1 < text.count else { return nil }
                if text[next] == "\\", text[next + 1] == "u" {
                    guard let low = hex(at: next + 2) else { return nil }
                    if (0xDC00...0xDFFF).contains(low) {
                        let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        decoded.append(Unicode.Scalar(combined) ?? "\u{FFFD}")
                        return (decoded, 12)
                    }
                }
                decoded.append("\u{FFFD}")
                return (decoded, 6)
            default:
                decoded.append(text[start + 1])
            }
            return (decoded, 2)
        }

        private func hex(at start: Int) -> UInt32? {
            guard start + 4 <= text.count else { return nil }
            var value: UInt32 = 0
            for scalar in text[start..<(start + 4)] {
                guard let digit = Character(scalar).hexDigitValue else { return nil }
                value = value * 16 + UInt32(digit)
            }
            return value
        }

        /// The value at `index`, whatever its type. False when it runs past the end of the text.
        private mutating func skipValue() -> Bool {
            guard index < text.count else { return false }
            switch text[index] {
            case "\"":
                return string().complete
            case "{", "[":
                var depth = 0
                while index < text.count {
                    let scalar = text[index]
                    if scalar == "\"" {
                        guard string().complete else { return false }
                        continue
                    }
                    if scalar == "{" || scalar == "[" { depth += 1 }
                    if scalar == "}" || scalar == "]" { depth -= 1 }
                    index += 1
                    if depth == 0 { return true }
                }
                return false
            default:
                while index < text.count, !Self.valueEnd.contains(text[index]) { index += 1 }
                return index < text.count
            }
        }

        private static let valueEnd: Set<Unicode.Scalar> = [",", "}", "]", " ", "\n", "\r", "\t"]

        private mutating func skipWhitespace() {
            while index < text.count, text[index].properties.isWhitespace { index += 1 }
        }

        private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
            guard index < text.count, text[index] == scalar else { return false }
            index += 1
            return true
        }
    }
}
