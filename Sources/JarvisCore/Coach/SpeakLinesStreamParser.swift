import Foundation

/// Incrementally extracts completed `lines[]` strings from the streaming `arguments` JSON of a
/// `speak` tool call (`{"lines":["line one","line two",…]}`), emitting each line the moment its
/// closing quote arrives — so the overlay can show line 1 while the model is still generating line 2.
///
/// Pure and synchronous, so it is unit-tested without the network. Robust to chunk boundaries falling
/// anywhere (mid-string, mid-escape, mid-`\u` sequence) and to lines that themselves contain quotes,
/// brackets, commas, or backslashes (code). `\uXXXX` escapes in the Basic Multilingual Plane
/// (`→` decodes to an arrow, `—` to an em dash) are handled; astral/surrogate-pair escapes
/// (e.g. most emoji) are not — rare, since models emit raw UTF-8 in practice, and the final response
/// decode is authoritative anyway. (The earlier version passed `\uXXXX` through as the literal `uXXXX`,
/// which the driver then kept over the correctly-decoded line, garbling any tip with an arrow/dash/accent.)
struct SpeakLinesStreamParser {
    private var enteredArray = false   // consumed the `[` that opens the lines array
    private var inString = false
    private var escaped = false
    private var current = ""           // the in-progress (unescaped) string
    private var done = false           // saw the closing `]`
    private var unicodeRemaining = 0   // hex digits still to read in a `\uXXXX` escape (0 = not in one)
    private var unicodeHex = ""        // hex digits accumulated so far for the current `\u` escape

    /// Append a delta of the arguments JSON; return any lines it completed, in order.
    mutating func feed(_ delta: String) -> [String] {
        var completed: [String] = []
        for c in delta {
            if done { break }
            if !enteredArray {
                // The `speak` schema has exactly one array, so the first '[' opens `lines`.
                if c == "[" { enteredArray = true }
                continue
            }
            if inString {
                if unicodeRemaining > 0 {
                    // Collecting the 4 hex digits of a `\uXXXX` escape (may span feed() calls).
                    unicodeHex.append(c)
                    unicodeRemaining -= 1
                    if unicodeRemaining == 0 {
                        if let v = UInt32(unicodeHex, radix: 16), let scalar = Unicode.Scalar(v) {
                            current.append(Character(scalar))
                        }   // invalid (e.g. a lone surrogate half) is dropped; the final decode is authoritative
                        unicodeHex = ""
                    }
                } else if escaped {
                    escaped = false
                    if c == "u" { unicodeRemaining = 4; unicodeHex = "" }
                    else { current.append(Self.unescaped(c)) }
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    completed.append(current); current = ""; inString = false
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inString = true; current = ""
            } else if c == "]" {
                done = true
            }
            // commas / whitespace between elements are ignored
        }
        return completed
    }

    private static func unescaped(_ c: Character) -> Character {
        switch c {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        default:  return c   // \" \\ \/ → the char itself; \uXXXX is handled in feed(), not here
        }
    }
}
