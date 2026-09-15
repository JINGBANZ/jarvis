/// Stable Chrome tab state sampled before the screenshot. Read deadlines belong to each AX pass,
/// so synchronous screenshot latency cannot expire a later semantic-text read.
public struct BrowserDocumentIdentity: Sendable, Equatable {
    let value: String

    init(value: String) {
        self.value = value
    }
}
