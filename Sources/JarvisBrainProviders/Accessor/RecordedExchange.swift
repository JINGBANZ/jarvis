import Foundation
import JarvisCore

/// One `brain-traffic.jsonl` record as its wire format reads it, so nothing outside a wire format
/// parses a vendor's body.
public struct RecordedExchange: Equatable, Sendable {
    public struct Call: Equatable, Sendable {
        public let id: String?
        public let name: String?
        public let arguments: String?

        public init(id: String?, name: String?, arguments: String?) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    public struct Parameter: Equatable, Sendable {
        public let name: String
        public let value: String
    }

    public enum InputItem: Equatable, Sendable {
        case message(role: String, parts: [String])
        case call(Call)
        case result(callID: String?, output: String?)
        case reasoning(characters: Int)
        /// Plain content blocks, which only old local CLI records hold.
        case text(String?)
        case image(String?)
        case other(String)
    }

    public enum Output: Equatable, Sendable {
        case call(Call)
        case text(String)
        case reasoning
        case other(String)
    }

    public struct Usage: Equatable, Sendable {
        public let input: Int?
        public let cacheRead: Int?
        public let cacheWrite: Int?
        /// Includes reasoning tokens for every provider, so the column compares.
        public let output: Int?
        public let rendered: String
    }

    public var model: String?
    public var parameters: [Parameter] = []
    public var instructions: String?
    public var toolNames: [String] = []
    public var toolCount = 0
    public var toolsFingerprint = "[]"
    public var speakParameters: [String]?
    public var toolChoiceType: String?
    public var input: [InputItem] = []
    public var inputFingerprints: [String] = []
    public var status: String?
    public var incompleteDetail: String?
    public var outputs: [Output] = []
    public var usage: Usage?

    public init() {}

    public static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys, .fragmentsAllowed])
        else { return String(describing: value) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    mutating func readDeclaredTools(_ tools: Any?) {
        toolsFingerprint = Self.canonical(tools ?? [])
        toolCount = (tools as? [Any])?.count ?? 0
        let declared = tools as? [[String: Any]] ?? []
        toolNames = declared.compactMap { $0["name"] as? String }
        guard let speak = declared.first(where: { $0["name"] as? String == speakToolName }),
              let parameters = speak["parameters"] as? [String: Any],
              let properties = parameters["properties"] as? [String: Any]
        else {
            speakParameters = nil
            return
        }
        speakParameters = properties.keys.sorted()
    }
}
