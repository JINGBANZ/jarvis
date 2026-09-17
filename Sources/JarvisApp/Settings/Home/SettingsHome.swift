import AppKit
import JarvisCore

@MainActor
final class SettingsHome {
    /// The point is where the click happened, in window coordinates.
    var onOpen: ((SettingsDestination, NSPoint?) -> Void)?

    private let model: SettingsHubModel
    private var homeView: SettingsHomeView?
    private var scrollView: SettingsScrollView?
    private var observer: UUID?

    init(model: SettingsHubModel) {
        self.model = model
    }

    func makeView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
        container.autoresizingMask = [.width, .height]
        let scroll = SettingsScrollView(frame: container.bounds)
        scroll.autoresizingMask = [.width, .height]
        let home = SettingsHomeView(frame: container.bounds)
        home.onOpen = { [weak self] destination, point in self?.onOpen?(destination, point) }
        scroll.documentView = home
        scroll.onViewportChanged = { [weak self] in self?.fit() }
        container.addSubview(scroll)
        homeView = home
        scrollView = scroll
        observer = model.observe { [weak self] state in self?.homeView?.render(state) }
        fit()
        return container
    }

    func didBecomeActive() {
        model.refresh(probe: true)
        homeView?.robot.wantsAnimation = true
    }

    func didResignActive() {
        homeView?.highlightedPart = nil
        homeView?.robot.wantsAnimation = false
    }

    func windowWillClose() {
        if let observer { model.removeObserver(observer) }
        observer = nil
        homeView = nil
        scrollView = nil
    }

    private func fit() {
        guard let home = homeView, let scroll = scrollView else { return }
        let viewport = scroll.contentView.bounds.size
        home.viewportSize = viewport
        let height = home.isWideLayout
            ? viewport.height
            : max(viewport.height, home.requiredHeight(forWidth: viewport.width))
        home.setFrameSize(NSSize(width: viewport.width, height: height))
    }
}
