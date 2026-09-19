import Foundation

/// One event as the wire framed it: `event` is the `event:` field when present, `data` the
/// `data:` lines joined by newline.
struct ServerSentEvent: Equatable {
    let event: String?
    let data: String
}

/// Framing only: no JSON, no vendor knowledge. Bytes arrive in arbitrary chunks, and a line is
/// complete at its newline, so a multibyte character is never split by the reader.
struct ServerSentEventReader {
    private var pending: [UInt8] = []
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func receive(_ chunk: Data) -> [ServerSentEvent] {
        pending.append(contentsOf: chunk)
        var events: [ServerSentEvent] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            if let event = consume(line: line) { events.append(event) }
        }
        return events
    }

    /// A trailing event with no blank line after it.
    mutating func finish() -> ServerSentEvent? {
        if !pending.isEmpty {
            let line = pending[...]
            pending.removeAll()
            if let event = consume(line: line) { return event }
        }
        return dispatch()
    }

    private mutating func consume(line: ArraySlice<UInt8>) -> ServerSentEvent? {
        var line = line
        if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
        guard !line.isEmpty else { return dispatch() }
        guard line.first != UInt8(ascii: ":") else { return nil }
        let field: Substring
        var value: Substring
        let text = String(decoding: line, as: UTF8.self)
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = text[...]
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break   // `id`, `retry`, and fields added later carry nothing the reply needs
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            eventName = nil
            dataLines.removeAll()
        }
        guard !dataLines.isEmpty else { return nil }
        return ServerSentEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}
