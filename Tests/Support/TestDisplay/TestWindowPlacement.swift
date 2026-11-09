#if DEBUG
import CoreGraphics

enum TestWindowPlacement {
    static func frame(_ proposed: CGRect, within screen: CGRect) -> CGRect? {
        guard [proposed.minX, proposed.minY, proposed.width, proposed.height,
               screen.minX, screen.minY, screen.width, screen.height].allSatisfy(\.isFinite),
              proposed.width > 0, proposed.height > 0,
              proposed.width <= screen.width, proposed.height <= screen.height else { return nil }
        if screen.contains(proposed) { return proposed }
        return CGRect(x: screen.midX - proposed.width / 2, y: screen.midY - proposed.height / 2,
                      width: proposed.width, height: proposed.height)
    }
}
#endif
