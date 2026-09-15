/// Finds editor controls before general page traversal consumes the shared byte budget.
enum AccessibilityTraversal {
    static func editorElements<Element>(
        in roots: [Element],
        role: (Element) -> String,
        children: (Element) -> [Element],
        limit: Int
    ) -> [Element] {
        var queue = roots
        var cursor = 0
        var visited = 0
        var textAreas: [Element] = []
        var textFields: [Element] = []
        while cursor < queue.count, visited < limit {
            let element = queue[cursor]
            cursor += 1
            visited += 1
            switch role(element) {
            case "AXTextArea":
                textAreas.append(element)
            case "AXTextField":
                textFields.append(element)
            case "AXSecureTextField":
                continue
            default:
                let remaining = max(0, limit - queue.count)
                queue.append(contentsOf: children(element).prefix(remaining))
            }
        }
        return textAreas + textFields
    }
}
