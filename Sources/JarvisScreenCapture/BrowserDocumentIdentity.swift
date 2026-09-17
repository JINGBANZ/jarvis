/// Sampled before the screenshot. Each later AX pass takes its own deadline, so screenshot latency
/// cannot expire the text read.
public struct BrowserDocumentIdentity: Sendable, Equatable {
    let value: String

    init(value: String) {
        self.value = value
    }
}
