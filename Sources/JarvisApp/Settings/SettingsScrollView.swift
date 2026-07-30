import AppKit

/// Reports viewport changes so responsive Settings documents can resize their cards and remain
/// top-aligned without teaching the shared page shell about section-specific document heights.
@MainActor
final class SettingsScrollView: NSScrollView {
    var onViewportChanged: (() -> Void)?
    private var lastViewportSize = NSSize.zero

    override func layout() {
        super.layout()
        let size = contentView.bounds.size
        guard size != lastViewportSize else { return }
        lastViewportSize = size
        onViewportChanged?()
    }
}
