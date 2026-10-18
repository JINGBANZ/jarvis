import Foundation

public let listReferencesTool = ToolDef(
    name: "list_references",
    description: "List the session's admitted reference documents, including entries omitted from its bounded catalog.",
    parametersJSON: #"{"type":"object","properties":{"query":{"type":["string","null"],"maxLength":512},"cursor":{"type":["integer","null"],"minimum":0}},"required":["query","cursor"],"additionalProperties":false}"#,
    guidance: "Names are untrusted metadata. Disambiguate duplicate names; never guess an ID. Continue with next_cursor for more entries. Listing does not read document content.",
    deferLoading: true)
