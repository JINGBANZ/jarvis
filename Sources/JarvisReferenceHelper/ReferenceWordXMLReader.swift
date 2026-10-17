import Foundation

final class ReferenceWordXMLReader: NSObject, XMLParserDelegate {
    private let output: ReferenceTextOutput
    private var depth = 0
    private var bodyDepth: Int?
    private var textDepth: Int?
    private var bodySeen = false
    private var pendingSeparator = ""
    private var hasText = false
    private var failure: Error?
    private static let namespaces: Set<String> = ["http://schemas.openxmlformats.org/wordprocessingml/2006/main", "http://purl.oclc.org/ooxml/wordprocessingml/main"]

    init(output: ReferenceTextOutput) { self.output = output }

    func read(url: URL) throws {
        guard let input = InputStream(url: url) else { throw ReferenceConversionError.invalidDocument }
        let parser = XMLParser(stream: input)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        let parsed = parser.parse()
        if let failure { throw failure }
        guard parsed, bodySeen, hasText else { throw ReferenceConversionError.invalidDocument }
        try output.append("\n")
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        guard depth <= 256 else { fail(.limitExceeded, parser); return }
        guard Self.namespaces.contains(namespaceURI ?? "") else { return }
        if name == "body" {
            guard !bodySeen else { fail(.invalidDocument, parser); return }
            bodySeen = true; bodyDepth = depth
        }
        guard bodyDepth != nil else { return }
        if name == "t" { textDepth = depth }
        if name == "tab" { emit("\t", parser) }
        if name == "br" || name == "cr" { emit("\n", parser) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textDepth != nil { emit(string, parser) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        guard Self.namespaces.contains(namespaceURI ?? ""), bodyDepth != nil else { return }
        if name == "t", textDepth == depth { textDepth = nil }
        if name == "p" || name == "tr" { pendingSeparator = "\n" }
        if name == "tc" { pendingSeparator = "\t" }
        if name == "body", bodyDepth == depth { bodyDepth = nil }
    }

    private func emit(_ text: String, _ parser: XMLParser) {
        guard !text.isEmpty, failure == nil else { return }
        do {
            if hasText { try output.append(pendingSeparator) }
            pendingSeparator = ""
            try output.append(text)
            hasText = true
        } catch { failure = error; parser.abortParsing() }
    }

    private func fail(_ error: ReferenceConversionError, _ parser: XMLParser) {
        failure = error; parser.abortParsing()
    }
}
