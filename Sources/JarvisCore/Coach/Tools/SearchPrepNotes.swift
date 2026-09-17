import Foundation

public let searchPrepNotesTool = ToolDef(
    name: "search_prep_notes",
    description: "Search the user's own prepared interview notes for content "
        + "relevant to the current question. Use when a live question resembles a topic they've "
        + "prepared. If results only point to another section, one focused follow-up may retrieve it.",
    parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#,
    guidance: """
        # Prep material
        If a live question resembles a topic in the user's prepared notes, call search_prep_notes once
        before speaking on that topic, then let the result inform — not replace — your own reasoning.
        If results only point to a named story or section and lack the facts needed to answer,
        make at most one focused follow-up search using that title and its identifying details.
        Otherwise do not repeat the search. Empty or unavailable results are not grounds to retry.
        Query with the specific detail being discussed right now, not the overall problem name — a
        broad query can match the wrong section of their notes. Skip it when the question does not
        resemble anything they would have prepared.
        """,
    deferLoading: true
)

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
