import Foundation

public final class OverlayAppearance {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Detail box

    public var detailFontSize: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Detail.fontSizeKey) != nil else {
                return Defaults.Overlay.Detail.fontSize
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Detail.fontSizeKey),
                to: Defaults.Overlay.Detail.fontSizeRange,
                fallback: Defaults.Overlay.Detail.fontSize)
        }
        set {
            defaults.set(
                Self.clamp(
                    newValue,
                    to: Defaults.Overlay.Detail.fontSizeRange,
                    fallback: Defaults.Overlay.Detail.fontSize),
                forKey: Defaults.Overlay.Detail.fontSizeKey)
        }
    }

    public var detailBackgroundOpacity: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Detail.opacityKey) != nil else {
                return Defaults.Overlay.Detail.opacity
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Detail.opacityKey),
                to: Defaults.Overlay.Detail.opacityRange,
                fallback: Defaults.Overlay.Detail.opacity)
        }
        set {
            defaults.set(
                Self.clamp(
                    newValue,
                    to: Defaults.Overlay.Detail.opacityRange,
                    fallback: Defaults.Overlay.Detail.opacity),
                forKey: Defaults.Overlay.Detail.opacityKey)
        }
    }

    // MARK: - Overlay Box (persistent response history)

    public var boxFontSize: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Box.fontSizeKey) != nil else {
                return Defaults.Overlay.Box.fontSize
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Box.fontSizeKey),
                to: Defaults.Overlay.Box.fontSizeRange,
                fallback: Defaults.Overlay.Box.fontSize)
        }
        set {
            defaults.set(
                Self.clamp(
                    newValue,
                    to: Defaults.Overlay.Box.fontSizeRange,
                    fallback: Defaults.Overlay.Box.fontSize),
                forKey: Defaults.Overlay.Box.fontSizeKey)
        }
    }

    public var boxOpacity: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Box.opacityKey) != nil else {
                return Defaults.Overlay.Box.opacity
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Box.opacityKey),
                to: Defaults.Overlay.Box.opacityRange,
                fallback: Defaults.Overlay.Box.opacity)
        }
        set {
            defaults.set(
                Self.clamp(
                    newValue,
                    to: Defaults.Overlay.Box.opacityRange,
                    fallback: Defaults.Overlay.Box.opacity),
                forKey: Defaults.Overlay.Box.opacityKey)
        }
    }

    /// In points.
    public var boxWidth: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Box.widthKey) != nil else {
                return Defaults.Overlay.Box.width
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Box.widthKey),
                to: Defaults.Overlay.Box.widthRange,
                fallback: Defaults.Overlay.Box.width)
        }
        set {
            defaults.set(
                Self.clamp(
                    newValue,
                    to: Defaults.Overlay.Box.widthRange,
                    fallback: Defaults.Overlay.Box.width),
                forKey: Defaults.Overlay.Box.widthKey)
        }
    }

    /// In points.
    public var boxHeight: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Box.heightKey) != nil else {
                return Defaults.Overlay.Box.height
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Box.heightKey),
                to: Defaults.Overlay.Box.heightRange,
                fallback: Defaults.Overlay.Box.height)
        }
        set {
            defaults.set(
                Self.clamp(
                    newValue,
                    to: Defaults.Overlay.Box.heightRange,
                    fallback: Defaults.Overlay.Box.height),
                forKey: Defaults.Overlay.Box.heightKey)
        }
    }

    public var boxEnabled: Bool {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Box.enabledKey) != nil else {
                return Defaults.Overlay.Box.enabled
            }
            return defaults.bool(forKey: Defaults.Overlay.Box.enabledKey)
        }
        set { defaults.set(newValue, forKey: Defaults.Overlay.Box.enabledKey) }
    }

    /// Non-finite input (a corrupt plist value) returns `fallback`, not a bound: clamping it to an
    /// opacity floor of 0 would make the backdrop invisible.
    private static func clamp(
        _ v: Double,
        to r: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard v.isFinite else { return fallback }
        return min(max(v, r.lowerBound), r.upperBound)
    }
}

@MainActor
public protocol OverlayBoxApplying: AnyObject {
    func setDetailFontSize(_ points: Double)
    func setDetailBackgroundOpacity(_ opacity: Double)
    func setOpacity(_ opacity: Double)
    func setFontSize(_ points: Double)
    /// Content width and height in points, once per finished resize drag. Never fires for the
    /// restored size, which is supplied at construction.
    var onSizeChanged: ((Double, Double) -> Void)? { get set }
    func setEnabled(_ enabled: Bool)
    /// Off restores the real log and prior visibility. Must preserve screen-capture exclusion.
    func showAppearancePreview(_ on: Bool)
}
