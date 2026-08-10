import Foundation

/// Parses JSONL without hiding damaged records. Consumers use the stable non-blank record number
/// for call labels and carry `malformedCount` into availability wording instead of treating a
/// truncated append as if it never existed.
enum JSONLRecords {
    struct Line {
        let number: Int
        let object: [String: Any]?
    }

    struct Parsed {
        let lines: [Line]

        var objects: [[String: Any]] {
            lines.compactMap(\.object)
        }

        var malformedCount: Int {
            lines.count(where: { $0.object == nil })
        }
    }

    static func parse(_ jsonl: String) -> Parsed {
        var lines: [Line] = []
        var number = 0
        for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !raw.allSatisfy(\.isWhitespace) else { continue }
            number += 1
            let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)))
                as? [String: Any]
            lines.append(Line(number: number, object: object))
        }
        return Parsed(lines: lines)
    }
}
