import Foundation

final class ReferencePackageRelationships: NSObject, XMLParserDelegate {
    private(set) var target: String?
    private var invalid = false

    static func mainDocument(in data: Data) throws -> String {
        let reader = ReferencePackageRelationships()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.invalid, let target = reader.target,
              let decoded = target.removingPercentEncoding, !decoded.contains(":"), !decoded.contains("\\"),
              !decoded.contains("?"), !decoded.contains("#") else { throw ReferenceConversionError.invalidDocument }
        let path = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        guard !path.isEmpty, path.utf8.count <= 1_024,
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ReferenceConversionError.invalidDocument
        }
        return path
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard name == "Relationship", namespaceURI == "http://schemas.openxmlformats.org/package/2006/relationships",
              let type = attributes["Type"], ["http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument",
                "http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument"].contains(type) else { return }
        guard target == nil, attributes["TargetMode"] != "External", let value = attributes["Target"] else {
            invalid = true; parser.abortParsing(); return
        }
        target = value
    }
}
