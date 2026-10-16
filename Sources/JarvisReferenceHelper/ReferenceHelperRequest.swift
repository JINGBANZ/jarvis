import Foundation
import JarvisCore

struct ReferenceHelperRequest: Sendable {
    let id: UUID
    let operation: String
    let session: UUID?
    let payload: Data

    private struct Header: Decodable {
        let `protocol`: Int
        let id: UUID
        let operation: String
        let session_id: UUID?
    }

    init(_ body: Data) throws {
        let header = try JSONDecoder().decode(Header.self, from: body)
        guard header.protocol == 1,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { throw ReferenceProtocolError.malformed }
        id = header.id; operation = header.operation; session = header.session_id
        self.payload = try JSONSerialization.data(withJSONObject: payload)
    }
}
