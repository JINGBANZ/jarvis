import Foundation
import Testing
@testable import JarvisCore

@Suite("Document catalog")
struct DocumentCatalogTests {
    private func entry(_ value: Int, name: String = "Reference.txt") -> DocumentCatalog.Entry {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
        return .init(documentID: id, name: name, format: "txt")
    }

    @Test func promptBoundsDoNotReduceFullMembershipCounts() throws {
        let members = (0..<500).map { entry($0) }
        let catalog = try DocumentCatalog.bounded(members)
        #expect(catalog.entries.count <= 200)
        #expect(catalog.totalCount == 500)
        #expect(catalog.omittedCount == 500 - catalog.entries.count)
        #expect(try catalog.serialized().count <= 16 * 1024)
        #expect(try DocumentCatalog.bounded(Array(members.reversed())).serialized() == catalog.serialized())
    }

    @Test func databasePrefixKeepsFullLocalMembershipCount() throws {
        let catalog = try DocumentCatalog.bounded([entry(1), entry(2)], totalCount: 100_000)
        #expect(catalog.totalCount == 100_000)
        #expect(catalog.omittedCount == 99_998)
        #expect(throws: ReferenceProtocolError.self) { try DocumentCatalog.bounded([entry(1)], totalCount: 0) }
    }

    @Test func escapedMultibyteNamesRespectSerializedByteLimit() throws {
        let members = (0..<30).map { entry($0, name: String(repeating: "中文😀\"\n", count: 100)) }
        let catalog = try DocumentCatalog.bounded(members)
        #expect(catalog.entries.count < 30)
        #expect(try catalog.serialized().count <= DocumentCatalog.maximumBytes)
        let context = try SessionContext(documentCatalog: catalog)
        #expect(context.serialized == (try SessionContext(documentCatalog: catalog)).serialized)
        #expect(context.documentCatalog == catalog)
    }

    @Test func untrustedCatalogMustMatchCountsBoundsAndPathPolicy() throws {
        let id = UUID().uuidString
        let objects: [[String: Any]] = [
            ["entries": [["document_id": id, "name": "/private/source.txt", "format": "txt"]], "total_count": 1, "omitted_count": 0],
            ["entries": [], "total_count": 5, "omitted_count": 0],
            ["entries": [["document_id": id, "name": "x", "format": "txt"], ["document_id": id, "name": "y", "format": "txt"]], "total_count": 2, "omitted_count": 0],
        ]
        for object in objects {
            let data = try JSONSerialization.data(withJSONObject: object)
            let catalog = try JSONDecoder().decode(DocumentCatalog.self, from: data)
            #expect(throws: ReferenceProtocolError.self) { try SessionContext(documentCatalog: catalog) }
        }
    }

    @Test func emptyContextDoesNotInventReferenceMetadata() throws {
        let context = try SessionContext(documentCatalog: nil)
        #expect(context.documentCatalog == nil)
        #expect(String(decoding: context.serialized, as: UTF8.self) == "{}")
    }
}
