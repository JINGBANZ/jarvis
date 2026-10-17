import Foundation

public enum ReferenceProtocolError: Error, Equatable, Sendable {
    case oversized, malformed, truncated, unexpectedResponse
}

/// Private stdio protocol: four-byte unsigned network-order length followed by UTF-8 JSON.
public struct ReferenceFrame: Sendable {
    public static let maximumBytes = 1_048_576
    private var buffer = Data()
    public init() {}

    public static func encode(_ body: Data) throws -> Data {
        guard !body.isEmpty, body.count <= maximumBytes else { throw ReferenceProtocolError.oversized }
        var length = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + body
    }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maximumBytes else { throw ReferenceProtocolError.oversized }
            guard buffer.count >= length + 4 else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(length + 4))
        }
        guard buffer.count <= Self.maximumBytes + 4 else { throw ReferenceProtocolError.oversized }
        return frames
    }

    public func finish() throws {
        guard buffer.isEmpty else { throw ReferenceProtocolError.truncated }
    }
}
