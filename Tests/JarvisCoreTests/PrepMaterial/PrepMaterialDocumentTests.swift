import Foundation
import Testing
@testable import JarvisCore

@Suite struct PrepMaterialDocumentTests {
    @Test func matchedDocumentCanBeReadInFullWithoutLosingMarkdown() throws {
        let original = "# Payment Design\n\nSession date\n\n## Architecture\n\nUse durable operations.\n\n## Appendix\n"
        let index = PrepMaterialIndex(documents: [
            PrepMaterialDocument(sourceDisplayName: "Payment.md", text: original),
        ])
        let hit = try #require(index.search(query: "Payment.md").first)
        let id = try #require(hit.documentID)
        let page = try #require(index.read(documentID: id, offset: 0))
        #expect(page.text == original)
        #expect(page.nextOffset == nil)
    }

    @Test func paginationPreservesUnicodeAndReportsTheRemainder() throws {
        let original = String(repeating: "支付 👩🏽‍💻\n", count: 6000)
        let index = PrepMaterialIndex(documents: [
            PrepMaterialDocument(sourceDisplayName: "Payment.md", text: original),
        ])
        let id = try #require(index.search(query: "Payment.md").first?.documentID)
        var offset = 0
        var text = ""
        repeat {
            let page = try #require(index.read(documentID: id, offset: offset))
            #expect(!page.text.isEmpty)
            #expect(page.text.count <= 16_000)
            text += page.text
            guard let next = page.nextOffset else { break }
            #expect(next > offset)
            offset = next
        } while true
        #expect(text == original)
        #expect(index.read(documentID: id, offset: -1) == nil)
        #expect(index.read(documentID: id, offset: Int.max) == nil)
        #expect(index.read(documentID: "/etc/passwd", offset: 0) == nil)
    }

    @Test func sameFilenamesHaveSeparateReadIdentities() throws {
        let index = PrepMaterialIndex(documents: [
            PrepMaterialDocument(sourceDisplayName: "notes.md", text: "authorization uniquealpha"),
            PrepMaterialDocument(sourceDisplayName: "notes.md", text: "settlement uniquebeta"),
        ])
        let first = try #require(index.search(query: "uniquealpha").first?.documentID)
        let second = try #require(index.search(query: "uniquebeta").first?.documentID)
        #expect(first != second)
        #expect(index.read(documentID: first, offset: 0)?.text == "authorization uniquealpha")
        #expect(index.read(documentID: second, offset: 0)?.text == "settlement uniquebeta")
    }
}
