import AppKit
import JarvisCore

/// The approved prototype's design space: top-left origin, y down.
extension RobotHeadView {
    static let designCrop = CGRect(x: 296, y: 110, width: 234, height: 282)
    static let neckRect = NSRect(x: 385, y: 370, width: 50, height: 16)
    static let earRects = [
        NSRect(x: 302, y: 216, width: 20, height: 56),
        NSRect(x: 498, y: 216, width: 20, height: 56),
    ]
    static let earLines = [
        (NSPoint(x: 308, y: 232), NSPoint(x: 308, y: 256)),
        (NSPoint(x: 514, y: 232), NSPoint(x: 514, y: 256)),
    ]
    static let antenna = (NSPoint(x: 512, y: 216), NSPoint(x: 524, y: 196))
    static let antennaTip = NSPoint(x: 525, y: 194)
    static let visorRect = NSRect(x: 340, y: 212, width: 140, height: 42)
    static let eyeCenters = [NSPoint(x: 382, y: 233), NSPoint(x: 438, y: 233)]
    static let mouthRect = NSRect(x: 374, y: 292, width: 72, height: 46)
    /// x, the two heights it swings between, and the swing period in seconds.
    static let mouthBars: [(x: CGFloat, from: CGFloat, to: CGFloat, period: Double)] = [
        (386, 12, 20, 1.2), (397, 24, 12, 1.4), (408, 32, 18, 1.0), (419, 20, 28, 1.3), (430, 10, 16, 1.1),
    ]
    static let circuitLines: [[NSPoint]] = [
        [NSPoint(x: 352, y: 184), NSPoint(x: 352, y: 170), NSPoint(x: 372, y: 170), NSPoint(x: 372, y: 156)],
        [NSPoint(x: 392, y: 184), NSPoint(x: 392, y: 164), NSPoint(x: 410, y: 164), NSPoint(x: 410, y: 146)],
        [NSPoint(x: 430, y: 184), NSPoint(x: 430, y: 172), NSPoint(x: 452, y: 172), NSPoint(x: 452, y: 158)],
        [NSPoint(x: 470, y: 184), NSPoint(x: 470, y: 174)],
    ]
    /// Dot centers, pulse periods, and whether a dot starts dim (the pulses alternate).
    static let circuitDots: [(center: NSPoint, period: Double, startsDim: Bool)] = [
        (NSPoint(x: 372, y: 156), 1.8, false), (NSPoint(x: 410, y: 146), 1.8, true),
        (NSPoint(x: 452, y: 158), 2.2, false), (NSPoint(x: 470, y: 174), 2.2, true),
    ]

    static func shellPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 320, y: 200))
        path.curve(to: NSPoint(x: 410, y: 118),
                   controlPoint1: NSPoint(x: 320, y: 140), controlPoint2: NSPoint(x: 360, y: 118))
        path.curve(to: NSPoint(x: 500, y: 200),
                   controlPoint1: NSPoint(x: 460, y: 118), controlPoint2: NSPoint(x: 500, y: 140))
        path.line(to: NSPoint(x: 500, y: 300))
        path.curve(to: NSPoint(x: 410, y: 372),
                   controlPoint1: NSPoint(x: 500, y: 346), controlPoint2: NSPoint(x: 462, y: 372))
        path.curve(to: NSPoint(x: 320, y: 300),
                   controlPoint1: NSPoint(x: 358, y: 372), controlPoint2: NSPoint(x: 320, y: 346))
        path.close()
        return path
    }

    static func domePath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 336, y: 194))
        path.curve(to: NSPoint(x: 410, y: 134),
                   controlPoint1: NSPoint(x: 338, y: 152), controlPoint2: NSPoint(x: 366, y: 134))
        path.curve(to: NSPoint(x: 484, y: 194),
                   controlPoint1: NSPoint(x: 454, y: 134), controlPoint2: NSPoint(x: 482, y: 152))
        path.close()
        return path
    }

    /// The ears get a few points of slack because they are thin.
    static func hitPath(for part: RobotPart) -> NSBezierPath {
        switch part {
        case .brain:
            return domePath()
        case .ear:
            let path = NSBezierPath()
            for rect in earRects {
                path.appendRoundedRect(rect.insetBy(dx: -4, dy: -4), xRadius: 12, yRadius: 12)
            }
            return path
        case .eye:
            return NSBezierPath(roundedRect: visorRect, xRadius: 21, yRadius: 21)
        case .mouth:
            return NSBezierPath(roundedRect: mouthRect, xRadius: 10, yRadius: 10)
        }
    }
}
