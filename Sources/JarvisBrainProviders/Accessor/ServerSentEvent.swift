import Foundation

/// One event as the wire framed it: `event` is the `event:` field when present, `data` the
/// `data:` lines joined by newline.
struct ServerSentEvent: Equatable {
    let event: String?
    let data: String
}
