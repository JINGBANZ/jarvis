import Foundation

public enum ReferenceSearchTokenizer {
    public struct Term: Equatable, Sendable {
        public let value: String
        public let offset: Int
        public let endOffset: Int
    }

    public static let version = "unicode-identifier-2"

    public static func folded(_ value: String) -> String {
        value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }

    public static func terms(_ text: String) -> [Term] {
        var result: [Term] = []
        var word = String.UnicodeScalarView()
        var start = 0
        var position = 0
        var previousCJK: (Unicode.Scalar, Int)?
        func emit(_ value: String, _ start: Int, _ end: Int) {
            let scalars = value.unicodeScalars
            let trimmed = scalars.reversed().drop(while: { "._-/".unicodeScalars.contains($0) }).reversed()
            guard trimmed.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return }
            let text = String(String.UnicodeScalarView(trimmed))
            guard text.utf8.count <= 2_048 else { return }
            result.append(Term(value: folded(text), offset: start, endOffset: end - (scalars.count - trimmed.count)))
        }
        func flush() {
            guard !word.isEmpty else { return }
            let full = String(word)
            emit(full, start, position)
            // Identifiers retain punctuation as one term; their components also support topic queries.
            if full.unicodeScalars.contains(where: { !CharacterSet.alphanumerics.contains($0) && !CharacterSet.nonBaseCharacters.contains($0) }) {
                var component = String.UnicodeScalarView()
                var begin = start
                for (index, scalar) in full.unicodeScalars.enumerated() {
                    if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                        if component.isEmpty { begin = start + index }
                        component.append(scalar)
                    } else if !component.isEmpty {
                        emit(String(component), begin, start + index); component = .init()
                    }
                }
                emit(String(component), begin, position)
            }
            word = .init()
        }
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                flush()
                emit(String(scalar), position, position + 1)
                if let previousCJK { emit(String(previousCJK.0) + String(scalar), previousCJK.1, position + 1) }
                previousCJK = (scalar, position)
            } else {
                previousCJK = nil
                if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
                    || "_+-#./".unicodeScalars.contains(scalar) {
                    if word.isEmpty { start = position }
                    word.append(scalar)
                } else { flush() }
            }
            position += 1
        }
        flush()
        // Add mixed-script punctuation identifiers without collapsing '-', '_' or spaces.
        var identifier = String.UnicodeScalarView()
        var begin = 0
        var cursor = 0
        func identifierFlush() {
            let value = String(identifier)
            if value.unicodeScalars.contains(where: { "_+-#./".unicodeScalars.contains($0) }),
               value.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                emit(value, begin, cursor)
            }
            identifier = .init()
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
                || "_+-#./".unicodeScalars.contains(scalar) {
                if identifier.isEmpty { begin = cursor }
                identifier.append(scalar)
            } else { identifierFlush() }
            cursor += 1
        }
        identifierFlush()
        return result
    }

    public static func encoded(_ value: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = [116]
        bytes.reserveCapacity(value.utf8.count * 2 + 1)
        for byte in value.utf8 { bytes.append(digits[Int(byte >> 4)]); bytes.append(digits[Int(byte & 15)]) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func indexedText(_ text: String) -> String { terms(text).map { encoded($0.value) }.joined(separator: " ") }

    public static func queryTerms(_ query: String) -> Set<String> {
        let terms = terms(query)
        let identifierTerms = terms.filter { isIdentifier($0.value) }
        let identifiers = Set(identifierTerms.filter { term in
            !identifierTerms.contains { other in
                other.offset <= term.offset && other.endOffset >= term.endOffset
                    && (other.offset < term.offset || other.endOffset > term.endOffset)
            }
        }.map(\.value))
        // An explicit identifier must match exactly; its loose component terms cannot satisfy it.
        let cjkPairs = terms.filter { $0.value.unicodeScalars.count == 2 && $0.value.unicodeScalars.allSatisfy(isCJK) }
        let ordinary = terms.filter { term in
            cjkPairs.isEmpty || !(term.value.unicodeScalars.count == 1 && term.value.unicodeScalars.allSatisfy(isCJK))
        }
        return identifiers.isEmpty ? Set(ordinary.map(\.value)) : identifiers
    }

    public static func matchExpression(_ query: String) -> String? {
        let selected = queryTerms(query)
        guard !selected.isEmpty else { return nil }
        return selected.sorted().map { "\"" + encoded($0) + "\"" }.joined(separator: selected.contains(where: isIdentifier) ? " AND " : " OR ")
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: { "_+-#./".unicodeScalars.contains($0) })
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9fff).contains(scalar.value) || (0x20000...0x323af).contains(scalar.value)
            || (0x3040...0x30ff).contains(scalar.value) || (0xac00...0xd7af).contains(scalar.value)
    }
}
