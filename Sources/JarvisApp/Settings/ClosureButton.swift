import AppKit

/// A tiny target/action adapter that lets a button's tap be a plain Swift closure instead of AppKit's
/// target/action selector pair. Shared by every Settings row that needs a lightweight per-row action
/// button — a fallback route's move/remove controls, a prep-material source's remove.
@MainActor
final class ClosureButton: NSButton {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.closure = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(performAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performAction() {
        closure()
    }
}
