import Foundation

/// Optional maintenance on the selected terminal action. Strict decoding is intentional: malformed
/// CLI metadata must not turn a string such as "false" into destructive question-reset authority.
struct ScreenMemoryUpdate: Decodable, Equatable {
    let newQuestion: Bool
    let obsoleteObservationIDs: [Int]

    static func parse(_ arguments: String) -> Self? {
        struct Envelope: Decodable { let screenMemory: ScreenMemoryUpdate? }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(arguments.utf8)),
              let update = envelope.screenMemory,
              update.obsoleteObservationIDs.count <= 32,
              update.obsoleteObservationIDs.allSatisfy({ $0 > 0 }) else { return nil }
        return update
    }
}
