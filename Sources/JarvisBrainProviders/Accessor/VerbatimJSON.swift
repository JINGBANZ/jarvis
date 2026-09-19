import Foundation

/// `JSONSerialization` writes a dictionary's keys in no particular order, but a model writes tool
/// arguments in the order its schema lists them, so an authored schema reaches the body as its own
/// text: each fragment is serialized as a placeholder and spliced back in unchanged.
struct VerbatimJSON {
    private var fragments: [(placeholder: String, json: String)] = []

    /// The value to put in the object where `json` belongs. Every call mints its own placeholder,
    /// so two tools with the same schema each get one.
    mutating func placeholder(for json: String) throws -> String {
        _ = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let placeholder = "verbatim-json-" + UUID().uuidString
        fragments.append((placeholder, json))
        return placeholder
    }

    func data(withJSONObject object: Any) throws -> Data {
        var text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        for (placeholder, json) in fragments {
            let quoted = "\"\(placeholder)\""
            guard let range = text.range(of: quoted) else {
                preconditionFailure("the placeholder for \(json) was never put in the object")
            }
            precondition(text[range.upperBound...].range(of: quoted) == nil,
                         "the placeholder for \(json) was put in the object more than once")
            text.replaceSubrange(range, with: json)
        }
        return Data(text.utf8)
    }
}
