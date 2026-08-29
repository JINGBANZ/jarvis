import Testing
@testable import JarvisCore

@Suite struct PrepMaterialIndexTests {
    @Test func emptyIndexReturnsNoResults() {
        let index = PrepMaterialIndex(chunks: [])
        #expect(index.search(query: "rate limiter").isEmpty)
    }

    @Test func emptyQueryReturnsNoResults() {
        let index = PrepMaterialIndex(chunks: [
            PrepMaterialChunk(sourceDisplayName: "notes.md", text: "design a rate limiter using tokens"),
        ])
        #expect(index.search(query: "").isEmpty)
        #expect(index.search(query: "   ").isEmpty)
    }

    @Test func queryWithNoMatchingTermsReturnsNoResults() {
        let index = PrepMaterialIndex(chunks: [
            PrepMaterialChunk(sourceDisplayName: "notes.md", text: "design a rate limiter using tokens"),
        ])
        #expect(index.search(query: "binary search tree rotations").isEmpty)
    }

    @Test func queryMatchesTheRelevantChunk() {
        let index = PrepMaterialIndex(chunks: [
            PrepMaterialChunk(sourceDisplayName: "rate-limiter.md", text: "design a rate limiter using a token bucket algorithm"),
            PrepMaterialChunk(sourceDisplayName: "url-shortener.md", text: "design a url shortener with base62 encoding"),
        ])
        let results = index.search(query: "how would you design a rate limiter")
        #expect(results.first?.sourceDisplayName == "rate-limiter.md")
    }

    @Test func matchIsCaseInsensitive() {
        let index = PrepMaterialIndex(chunks: [
            PrepMaterialChunk(sourceDisplayName: "notes.md", text: "Design A Rate Limiter"),
        ])
        #expect(!index.search(query: "RATE LIMITER").isEmpty)
    }

    @Test func rankingFavorsMoreRelevantChunk() {
        let index = PrepMaterialIndex(chunks: [
            PrepMaterialChunk(
                sourceDisplayName: "strong.md",
                text: "rate limiter rate limiter token bucket rate limiter design"),
            PrepMaterialChunk(
                sourceDisplayName: "weak.md",
                text: "a brief mention of rate limiter in passing, mostly about something else entirely"),
        ])
        let results = index.search(query: "rate limiter")
        #expect(results.first?.sourceDisplayName == "strong.md")
    }

    @Test func resultsAreCappedAtThree() {
        let chunks = (0..<10).map {
            PrepMaterialChunk(sourceDisplayName: "notes-\($0).md", text: "rate limiter design number \($0)")
        }
        let index = PrepMaterialIndex(chunks: chunks)
        #expect(index.search(query: "rate limiter").count == 3)
    }
}
