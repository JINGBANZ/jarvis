import Foundation

public struct VisibleEvaluationReply: Codable, Sendable {
    public var hint: String
    public var detail: String?
    public var withdrawn: Bool
    public var snapshots: [String]
    public var at: Double
    public init(hint: String, detail: String? = nil, withdrawn: Bool = false,
                snapshots: [String] = [], at: Double = 0) {
        self.hint = hint; self.detail = detail; self.withdrawn = withdrawn
        self.snapshots = snapshots; self.at = at
    }
}
