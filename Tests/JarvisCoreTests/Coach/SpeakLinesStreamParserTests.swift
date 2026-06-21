import Testing
@testable import JarvisCore

@Suite struct SpeakLinesStreamParserTests {
    /// Feed the whole arguments JSON at once → all lines come out in order.
    @Test func emitsAllLinesFromSingleChunk() {
        var p = SpeakLinesStreamParser()
        let out = p.feed(#"{"lines":["one","two","three"]}"#)
        #expect(out == ["one", "two", "three"])
    }

    /// A line is emitted only when its closing quote arrives — not before.
    @Test func emitsEachLineWhenItCloses() {
        var p = SpeakLinesStreamParser()
        #expect(p.feed(#"{"lines":["par"#) == [])          // string still open
        #expect(p.feed(#"tial","#) == ["partial"])          // closed by the quote+comma
        #expect(p.feed(#""second"]}"#) == ["second"])
    }

    /// Chunk boundaries may fall anywhere, including mid-escape, and a line may contain quotes,
    /// brackets, commas and backslashes (code) without being split.
    @Test func handlesEscapesAndCodeAcrossArbitraryBoundaries() {
        var p = SpeakLinesStreamParser()
        var out: [String] = []
        for ch in #"{"lines":["Use `Array.from({length: n+1}, () => [])`.","say \"hi\""]}"# {
            out += p.feed(String(ch))   // one character at a time — worst-case boundaries
        }
        #expect(out == [#"Use `Array.from({length: n+1}, () => [])`."#, #"say "hi""#])
    }

    /// Escaped newline in a line is unescaped to a real newline.
    @Test func unescapesControlSequences() {
        var p = SpeakLinesStreamParser()
        #expect(p.feed(#"{"lines":["a\nb"]}"#) == ["a\nb"])
    }

    /// An empty lines array yields nothing.
    @Test func emptyArrayEmitsNothing() {
        var p = SpeakLinesStreamParser()
        #expect(p.feed(#"{"lines":[]}"#) == [])
    }

    /// A BMP `\uXXXX` escape decodes to its character (not the literal `uXXXX`) -- the regression that
    /// would otherwise garble any tip with an arrow, dash, or accented/non-English character.
    @Test func decodesBMPUnicodeEscape() {
        var p = SpeakLinesStreamParser()
        #expect(p.feed(#"{"lines":["x\u2014y"]}"#) == ["x\u{2014}y"])   // \u2014 (raw) decodes to an em dash
    }

    /// A `\uXXXX` escape split across feed() chunks (mid-sequence boundary) still decodes correctly.
    @Test func decodesUnicodeEscapeSplitAcrossChunks() {
        var p = SpeakLinesStreamParser()
        #expect(p.feed(#"{"lines":["a\u21"#) == [])        // mid-\u sequence: nothing emitted yet
        #expect(p.feed(#"92b"]}"#) == ["a\u{2192}b"])      // completes → -> right arrow
    }
}
