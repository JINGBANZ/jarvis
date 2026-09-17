import AppKit
import JarvisCore
import QuartzCore

/// Not an accessibility element: the hub's slots are the accessible path to the same pages.
@MainActor
final class RobotHeadView: NSView {
    enum Style: Equatable {
        case hero
        case badge(RobotPart)
    }

    var highlightedPart: RobotPart? {
        didSet { if oldValue != highlightedPart { needsDisplay = true } }
    }
    var isLive = false {
        didSet { if oldValue != isLive { needsDisplay = true } }
    }
    var wantsAnimation = false {
        didSet { updateAnimation() }
    }
    var onHover: ((RobotPart?) -> Void)?
    var onClick: ((RobotPart, NSPoint) -> Void)?

    private let style: Style
    /// Advanced only while the link runs, so stopping holds the pose. The mouth keeps its own clock
    /// so a change to `isLive` doesn't make the bars jump.
    private var animationTime: Double = 0
    private var mouthTime: Double = 0
    private var lastTick: CFTimeInterval?
    private var link: CADisplayLink?
    private var trackingArea: NSTrackingArea?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var pressedPart: RobotPart?

    override var isFlipped: Bool { true }

    init(style: Style) {
        self.style = style
        super.init(frame: NSRect(origin: .zero, size: Self.designCrop.size))
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        designTransform().concat()
        switch style {
        case .hero:
            drawHero(time: animationTime)
        case .badge(let part):
            drawBadge(lit: part)
        }
        context.restoreGraphicsState()
    }

    private var scale: CGFloat {
        min(bounds.width / Self.designCrop.width, bounds.height / Self.designCrop.height)
    }

    private var drawingOrigin: NSPoint {
        NSPoint(x: (bounds.width - Self.designCrop.width * scale) / 2,
                y: (bounds.height - Self.designCrop.height * scale) / 2)
    }

    private func designTransform() -> NSAffineTransform {
        let transform = NSAffineTransform()
        transform.translateX(by: drawingOrigin.x, yBy: drawingOrigin.y)
        transform.scale(by: scale)
        transform.translateX(by: -Self.designCrop.minX, yBy: -Self.designCrop.minY)
        return transform
    }

    private func drawHero(time: Double) {
        let lit = highlightedPart
        paint(NSBezierPath(roundedRect: Self.neckRect, xRadius: 3, yRadius: 3),
              fill: SettingsTheme.shell, stroke: SettingsTheme.purple.withAlphaComponent(0.7), width: 1)
        paint(Self.shellPath(), fill: SettingsTheme.shell, stroke: SettingsTheme.purple, width: 2)

        glowing(lit == .brain) {
            let hot = lit == .brain
            paint(Self.domePath(),
                  fill: hot ? SettingsTheme.highlightFill : SettingsTheme.dome,
                  stroke: hot ? SettingsTheme.teal : SettingsTheme.purple.withAlphaComponent(0.7),
                  width: hot ? 2.5 : 1)
            let circuit = hot ? SettingsTheme.teal : SettingsTheme.circuit.withAlphaComponent(0.8)
            for points in Self.circuitLines {
                let path = NSBezierPath()
                path.move(to: points[0])
                points.dropFirst().forEach { path.line(to: $0) }
                paint(path, fill: nil, stroke: circuit, width: 1.3)
            }
            for dot in Self.circuitDots {
                let phase = Self.swing(time, period: dot.period)
                let opacity = dot.startsDim ? 0.3 + 0.7 * phase : 1 - 0.7 * phase
                (hot ? SettingsTheme.teal : SettingsTheme.circuit).withAlphaComponent(opacity).setFill()
                NSBezierPath(ovalIn: NSRect(x: dot.center.x - 2.5, y: dot.center.y - 2.5, width: 5, height: 5)).fill()
            }
        }

        glowing(lit == .ear) {
            let hot = lit == .ear
            for rect in Self.earRects {
                paint(NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10),
                      fill: hot ? SettingsTheme.highlightFill : SettingsTheme.shell,
                      stroke: hot ? SettingsTheme.teal : SettingsTheme.purple,
                      width: hot ? 2.5 : 1.6)
            }
            for (from, to) in Self.earLines {
                segment(from, to, color: SettingsTheme.teal, width: 2)
            }
            segment(Self.antenna.0, Self.antenna.1,
                    color: hot ? SettingsTheme.teal : SettingsTheme.purple, width: 1.6)
            SettingsTheme.teal.setFill()
            NSBezierPath(ovalIn: NSRect(x: Self.antennaTip.x - 3.5, y: Self.antennaTip.y - 3.5,
                                        width: 7, height: 7)).fill()
        }

        glowing(lit == .eye) {
            let hot = lit == .eye
            paint(NSBezierPath(roundedRect: Self.visorRect, xRadius: 21, yRadius: 21),
                  fill: SettingsTheme.visor,
                  stroke: hot ? SettingsTheme.teal : SettingsTheme.purple.withAlphaComponent(0.6),
                  width: hot ? 3 : 1)
        }
        drawEyes(verticalRadius: Self.eyeOpenness(time))

        glowing(lit == .mouth) {
            if lit == .mouth {
                paint(NSBezierPath(roundedRect: Self.mouthRect, xRadius: 10, yRadius: 10),
                      fill: SettingsTheme.highlightFill, stroke: SettingsTheme.teal, width: 2.5)
            }
            SettingsTheme.teal.setFill()
            for bar in Self.mouthBars {
                let height = bar.from + (bar.to - bar.from) * Self.swing(mouthTime, period: bar.period)
                NSBezierPath(roundedRect: NSRect(x: bar.x, y: 316 - height / 2, width: 5, height: height),
                             xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    private func drawEyes(verticalRadius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = SettingsTheme.eyeGlow
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = .zero
        shadow.set()
        SettingsTheme.eyeGlow.setFill()
        for center in Self.eyeCenters {
            NSBezierPath(ovalIn: NSRect(x: center.x - 15, y: center.y - verticalRadius,
                                        width: 30, height: verticalRadius * 2)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard isLive else { return }
        NSColor.white.withAlphaComponent(0.5).setFill()
        for center in Self.eyeCenters {
            NSBezierPath(ovalIn: NSRect(x: center.x - 9, y: center.y - verticalRadius * 0.6,
                                        width: 18, height: verticalRadius * 1.2)).fill()
        }
    }

    private func drawBadge(lit part: RobotPart) {
        let on = SettingsTheme.teal
        let off = SettingsTheme.purple.withAlphaComponent(0.55)
        paint(Self.shellPath(), fill: SettingsTheme.shell, stroke: SettingsTheme.purple, width: 5)
        paint(Self.domePath(), fill: part == .brain ? on : off, stroke: nil, width: 0)
        for rect in Self.earRects {
            paint(NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10),
                  fill: part == .ear ? on : off, stroke: nil, width: 0)
        }
        paint(NSBezierPath(roundedRect: Self.visorRect, xRadius: 21, yRadius: 21),
              fill: SettingsTheme.visor, stroke: nil, width: 0)
        (part == .eye ? SettingsTheme.eyeGlow : SettingsTheme.eyeOff).setFill()
        for center in Self.eyeCenters {
            NSBezierPath(ovalIn: NSRect(x: center.x - 15, y: center.y - 8, width: 30, height: 16)).fill()
        }
        paint(NSBezierPath(roundedRect: NSRect(x: 380, y: 300, width: 60, height: 30), xRadius: 6, yRadius: 6),
              fill: part == .mouth ? on : off, stroke: nil, width: 0)
    }

    private func paint(_ path: NSBezierPath, fill: NSColor?, stroke: NSColor?, width: CGFloat) {
        if let fill {
            fill.setFill()
            path.fill()
        }
        if let stroke {
            stroke.setStroke()
            path.lineWidth = width
            path.stroke()
        }
    }

    private func segment(_ from: NSPoint, _ to: NSPoint, color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineCapStyle = .round
        paint(path, fill: nil, stroke: color, width: width)
    }

    private func glowing(_ on: Bool, _ body: () -> Void) {
        guard on else { return body() }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = SettingsTheme.glow
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = .zero
        shadow.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func swing(_ time: Double, period: Double) -> CGFloat {
        CGFloat((1 - cos(2 * .pi * time / period)) / 2)
    }

    private static func eyeOpenness(_ time: Double) -> CGFloat {
        let u = time.truncatingRemainder(dividingBy: 4) / 4
        switch u {
        case 0.9..<0.93: return CGFloat(7 - 6 * (u - 0.9) / 0.03)
        case 0.93..<0.96: return CGFloat(1 + 6 * (u - 0.93) / 0.03)
        default: return 7
        }
    }

    // MARK: Pointer

    func part(at pointInView: NSPoint) -> RobotPart? {
        guard style == .hero, scale > 0 else { return nil }
        let design = NSPoint(
            x: (pointInView.x - drawingOrigin.x) / scale + Self.designCrop.minX,
            y: (pointInView.y - drawingOrigin.y) / scale + Self.designCrop.minY)
        // Front to back, so the visor and mouth win over the shell they sit on.
        return [RobotPart.mouth, .eye, .ear, .brain].first { Self.hitPath(for: $0).contains(design) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        style == .hero ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard style == .hero else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let hovered = part(at: convert(event.locationInWindow, from: nil))
        if hovered != highlightedPart {
            highlightedPart = hovered
            onHover?(hovered)
        }
        (hovered == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        if highlightedPart != nil {
            highlightedPart = nil
            onHover?(nil)
        }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        pressedPart = part(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedPart = nil }
        guard let released = part(at: convert(event.locationInWindow, from: nil)),
              released == pressedPart else { return }
        onClick?(released, event.locationInWindow)
    }

    // MARK: Animation

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
        if newWindow == nil {
            // The display link retains its target; release it with the window. No mouseExited
            // arrives when the hub leaves, so clear hover and the cursor here.
            link?.invalidate()
            link = nil
            lastTick = nil
            if highlightedPart != nil {
                highlightedPart = nil
                onHover?(nil)
                NSCursor.arrow.set()
            }
            return
        }
        guard style == .hero, let newWindow else { return }
        let windowNotifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in windowNotifications {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: newWindow, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateAnimation() }
            }
            observers.append((NotificationCenter.default, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let token = workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateAnimation()
                self?.needsDisplay = true
            }
        }
        observers.append((workspace, token))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    private func updateAnimation() {
        let shouldRun = style == .hero
            && wantsAnimation
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && window?.isKeyWindow == true
            && window?.occlusionState.contains(.visible) == true
        if shouldRun, link == nil {
            let newLink = displayLink(target: self, selector: #selector(tick))
            newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            newLink.add(to: .main, forMode: .common)
            link = newLink
        } else if !shouldRun, let link {
            link.invalidate()
            self.link = nil
            // The next start measures from its own first tick, so the pause isn't counted.
            lastTick = nil
            needsDisplay = true
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let lastTick {
            let elapsed = now - lastTick
            animationTime += elapsed
            mouthTime += elapsed * (isLive ? 1 / 0.7 : 1)
        }
        lastTick = now
        needsDisplay = true
    }
}
