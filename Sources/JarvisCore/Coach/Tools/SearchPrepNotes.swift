import Foundation

/// In the catalog only when the session has prep-material sources configured at Start. The search
/// port itself lands later, after indexing.
public let searchPrepNotesTool = ToolDef(
    name: "search_prep_notes",
    description: "Search the user's own prepared interview notes for content "
        + "relevant to the current question. Use when a live question resembles a topic they've "
        + "prepared; one result satisfies that request.",
    parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#,
    guidance: """
        # Prep material
        If a live question resembles a topic in the user's prepared notes, call search_prep_notes once
        before speaking on that topic, then let the result inform — not replace — your own reasoning.
        Query with the specific detail being discussed right now, not the overall problem name — a
        broad query can match the wrong section of their notes. Skip it when the question does not
        resemble anything they would have prepared.
        """,
    deferLoading: true
)

// The tool results the harness sends for a search.
extension JarvisPrompts.Coach {
    static func prepNotesResult(_ results: [PrepMaterialSearchResult]) -> String {
        guard !results.isEmpty else { return prepNotesNoResults }
        return results.enumerated().map { index, result in
            "[\(index + 1)] from \(result.sourceDisplayName):\n\(result.text)"
        }.joined(separator: "\n\n")
    }

    static let prepNotesNoResults = "nothing relevant found in the user's prepared notes"

    static let prepNotesUnavailable =
        "the user's prepared notes aren't available in this conversation; coach without them"
}
