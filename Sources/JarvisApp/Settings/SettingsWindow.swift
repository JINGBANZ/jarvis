import AppKit

/// The Settings window: the robot hub and the pages it opens. Non-modal; it promotes the accessory
/// app to `.regular` while open so text fields can take keyboard focus, and drops back on close —
/// the lesson the old API-key dialog and activity viewer both learned.
///
/// The window shell is kept between opens. The hub and each page are built on their first visit,
/// kept while the window is open, and released on close, so controls start fresh and the window
/// reopens on the hub. The views share a plain container rather than a tabless tab view, so a page
/// change can keep both on screen while it animates.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    /// One size for every page: navigating never resizes the window. The user can still resize
    /// freely down to `minContentSize`, which keeps the hub's compact layout and every page usable.
    private static let defaultContentSize = NSSize(width: 820, height: 600)
    private static let minContentSize = NSSize(width: 560, height: 460)

    private let home: SettingsHome
    private let sections: [SettingsDestination: SettingsSection]
    private let hub: SettingsHubModel
    private var window: NSWindow?
    private var container: SettingsPageContainer?
    private var homeView: NSView?
    private var pages: [SettingsDestination: SettingsPageView] = [:]
    private var current = SettingsDestination.home
    private var isShowingCurrent = false
    /// Guards a finished transition against a newer navigation or a closed window.
    private var transitionToken = 0
    /// Where the current page came from, so Back shrinks it into the same place.
    private var returnOrigin: NSPoint?

    init(home: SettingsHome, sections: [SettingsSection], hub: SettingsHubModel) {
        var byDestination: [SettingsDestination: SettingsSection] = [:]
        for section in sections {
            precondition(section.destination != .home, "the hub is not a section")
            precondition(byDestination[section.destination] == nil, "two sections for \(section.destination)")
            byDestination[section.destination] = section
        }
        self.home = home
        self.sections = byDestination
        self.hub = hub
        super.init()
        home.onOpen = { [weak self] destination, point in self?.open(destination, from: point) }
        hub.observe { [weak self] _ in self?.applyNotice() }
    }

    func show() {
        NSApp.setActivationPolicy(.regular) // ghost-mode-allowed: explicit Settings action
        if window == nil { build() }
        hub.beginObservingSettings()
        if !isShowingCurrent { present(current) }
        NSApp.activate(ignoringOtherApps: true) // ghost-mode-allowed: explicit Settings action
        window?.makeKeyAndOrderFront(nil) // ghost-mode-allowed: explicit Settings action
    }

    /// Shows `destination`, growing it out of `point` (window coordinates) when it opens from the hub.
    func open(_ destination: SettingsDestination, from point: NSPoint? = nil) {
        guard destination != current, destination == .home || sections[destination] != nil,
              let container, let outgoing = builtView(for: current) else { return }
        resignCurrent()
        let incoming = builtView(for: destination) ?? makeView(for: destination)
        incoming.frame = container.bounds
        incoming.autoresizingMask = [.width, .height]
        incoming.wantsLayer = true
        // An interrupted move can leave a third view behind; only these two take part.
        for view in container.subviews where view !== incoming && view !== outgoing {
            view.removeFromSuperview()
        }
        let direction: SettingsPageTransition.Direction = destination == .home ? .back : .forward
        if incoming.superview == nil {
            container.addSubview(incoming, positioned: direction == .forward ? .above : .below,
                                 relativeTo: outgoing)
        }
        if current == .home {
            returnOrigin = point.map { container.convert($0, from: nil) }
        }
        // Moves to and from the hub use the remembered origin; a page-to-page move (a notice's fix
        // button) grows from the center.
        let center = NSPoint(x: container.bounds.midX, y: container.bounds.midY)
        let origin = destination == .home || current == .home ? (returnOrigin ?? center) : center
        current = destination
        container.currentView = incoming
        isShowingCurrent = true
        if destination == .home {
            home.didBecomeActive()
        } else {
            sections[destination]?.didBecomeActive()
        }
        applyNotice()
        window?.makeFirstResponder(nil)

        transitionToken += 1
        let token = transitionToken
        SettingsPageTransition.run(direction, incoming: incoming, outgoing: outgoing, origin: origin) {
            [weak self, weak outgoing] in
            guard let self, token == self.transitionToken else { return }
            outgoing?.removeFromSuperview()
        }
    }

    func goHome() {
        open(.home)
    }

    private func build() {
        let win = EscapableWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Jarvis Settings"
        win.isReleasedWhenClosed = false
        win.contentMinSize = Self.minContentSize
        // Pages are added and removed while the window is open; let AppKit keep Tab order current.
        win.autorecalculatesKeyViewLoop = true
        win.delegate = self
        win.center()

        let content = win.contentView!
        let background = SettingsBackgroundView(frame: content.bounds)
        background.autoresizingMask = [.width, .height]
        content.addSubview(background)
        let container = SettingsPageContainer(frame: content.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        content.addSubview(container)
        self.window = win
        self.container = container
    }

    private func builtView(for destination: SettingsDestination) -> NSView? {
        destination == .home ? homeView : pages[destination]
    }

    private func makeView(for destination: SettingsDestination) -> NSView {
        if destination == .home {
            let view = home.makeView()
            homeView = view
            return view
        }
        guard let section = sections[destination] else { return NSView() }
        let page = section.makePage()
        page.onBack = { [weak self] in self?.goHome() }
        pages[destination] = page
        return page
    }

    /// Shows `destination` with no move, as the window opens.
    private func present(_ destination: SettingsDestination) {
        guard let container else { return }
        let view = builtView(for: destination) ?? makeView(for: destination)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        container.addSubview(view)
        container.currentView = view
        SettingsPageTransition.reset(view)
        isShowingCurrent = true
        if destination == .home {
            home.didBecomeActive()
        } else {
            sections[destination]?.didBecomeActive()
        }
        applyNotice()
    }

    private func resignCurrent() {
        guard isShowingCurrent else { return }
        isShowingCurrent = false
        if current == .home {
            home.didResignActive()
        } else {
            sections[current]?.didResignActive()
        }
    }

    /// The visible head page shows its part's advice, with a way to the fix when Settings has one.
    private func applyNotice() {
        guard let page = pages[current] else { return }
        guard let part = current.part,
              case .needsAttention(_, let advice, let fix)? = hub.state.slots[part]?.health else {
            page.setNotice(text: nil)
            return
        }
        switch fix {
        case .openConnections:
            page.setNotice(text: advice, actionTitle: "Open Connections") { [weak self] in
                self?.open(.connections)
            }
        case nil:
            page.setNotice(text: advice)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Coming back from System Settings is the usual way a grant changes.
        hub.refresh(probe: true)
    }

    func windowWillClose(_ notification: Notification) {
        resignCurrent()        // e.g. turn the overlay preview off if Mouth was open
        home.windowWillClose()
        for section in sections.values { section.windowWillClose() }
        hub.endObservingSettings()
        // Keep the window shell; release every page so controls start fresh next time. A transition
        // still running has nothing left to finish.
        transitionToken += 1
        returnOrigin = nil
        homeView?.removeFromSuperview()
        homeView = nil
        pages.values.forEach { $0.removeFromSuperview() }
        pages.removeAll()
        current = .home
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: close explicit Settings action
    }
}
