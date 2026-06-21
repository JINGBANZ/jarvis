import Foundation

/// Incrementally extracts completed `lines[]` strings from the streaming `arguments` JSON of a
/// `speak` tool call (`{"lines":["line one","line two",…]}`), emitting each line the moment its
/// closing quote arrives — so the overlay can show line 1 while the model is still generating line 2.
///
/// Pure and synchronous, so it is unit-tested without the network. Robust to chunk boundaries falling
/// anywhere (mid-string, mid-escape) and to lines that themselves contain quotes, brackets, commas, or
/// backslashes (code). Display-only / best-effort: `\uXXXX` escapes are passed through literally (rare
/// in coaching text) — the authoritative line set still comes from the final response decode, and the
/// driver renders any line the stream missed.
struct SpeakLinesStreamParser {
    private var enteredArray = false   // consumed the `[` that opens the lines array
    private var inString = false
    private var escaped = false
    private var current = ""           // the in-progress (unescaped) string
    private var done = false           // saw the closing `]`

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
                if escaped {
                    current.append(Self.unescaped(c)); escaped = false
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
        default:  return c   // \" \\ \/ → the char itself; \uXXXX passes through literally
        }
    }
}
