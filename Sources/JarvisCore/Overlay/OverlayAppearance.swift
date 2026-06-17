import Foundation

/// Persisted overlay appearance: font size (points) and background opacity (0–1). Backed by
/// UserDefaults; defaults and clamp bounds come from `Config`. Foundation-only so it stays
/// unit-testable in JarvisCore. Inject a `UserDefaults(suiteName:)` in tests.
public final class OverlayAppearance {
    private let defaults: UserDefaults

    private enum Key {
        static let fontSize = "overlay.fontSize"
        static let opacity = "overlay.backgroundOpacity"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var fontSize: Double {
        get {
            guard defaults.object(forKey: Key.fontSize) != nil else { return Config.overlayFontSizeDefault }
            return Self.clamp(defaults.double(forKey: Key.fontSize), to: Config.overlayFontSizeRange)
        }
        set { defaults.set(Self.clamp(newValue, to: Config.overlayFontSizeRange), forKey: Key.fontSize) }
    }

    public var backgroundOpacity: Double {
        get {
            guard defaults.object(forKey: Key.opacity) != nil else { return Config.overlayOpacityDefault }
            return Self.clamp(defaults.double(forKey: Key.opacity), to: Config.overlayOpacityRange)
        }
        set { defaults.set(Self.clamp(newValue, to: Config.overlayOpacityRange), forKey: Key.opacity) }
    }

    /// Clamp into `r`. Non-finite input (NaN/±inf — e.g. a corrupted plist value) falls back to the
    /// lower bound rather than propagating to `systemFont(ofSize:)` / `withAlphaComponent(:)`.
    private static func clamp(_ v: Double, to r: ClosedRange<Double>) -> Double {
        guard v.isFinite else { return r.lowerBound }
        return min(max(v, r.lowerBound), r.upperBound)
    }
}

/// How a settings panel pushes live appearance changes to the overlay without depending on AppKit.
/// The real `OverlayPanel` (in JarvisApp's overlay target) conforms; tests can supply a fake.
@MainActor
public protocol OverlayAppearanceApplying: AnyObject {
    func setFontSize(_ points: Double)
    func setBackgroundOpacity(_ opacity: Double)
    /// Show a sample tip (on) or clear it (off) so size/opacity changes are visible while the
    /// settings window is open. Must preserve screen-capture exclusion.
    func showAppearancePreview(_ on: Bool)
}
