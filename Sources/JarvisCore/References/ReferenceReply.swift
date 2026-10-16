import Foundation

public struct ReferenceReply: Sendable {
    public enum Status: String, Sendable { case ok, partial, unavailable, cancelled }
    public let id: UUID
    public let status: Status
    public let result: Data

    private struct Header: Decodable {
        let version: Int
        enum CodingKeys: String, CodingKey { case version = "protocol" }
    }
    public init(_ frame: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let header = try? JSONDecoder().decode(Header.self, from: frame), header.version == 1,
              let text = object["id"] as? String, let id = UUID(uuidString: text),
              let textStatus = object["status"] as? String, let status = Status(rawValue: textStatus),
              let result = object["result"] as? [String: Any] else {
            throw ReferenceProtocolError.malformed
        }
        self.id = id; self.status = status
        self.result = try JSONSerialization.data(withJSONObject: result)
    }
}
