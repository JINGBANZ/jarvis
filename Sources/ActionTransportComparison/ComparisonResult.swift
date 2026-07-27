struct ComparisonResult: Encodable {
    let provider: String
    let transport: String
    let processCount: Int
    let captureCount: Int
    let validTerminal: Bool
    let evidenceUsed: Bool
    let terminal: String?
    let elapsedMs: Int
    let error: String?
}
