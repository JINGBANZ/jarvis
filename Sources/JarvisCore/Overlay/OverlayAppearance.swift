import Foundation

/// Persisted overlay appearance for both overlay surfaces — the Overlay Caption (the transient
/// on-screen tip) and the Overlay Box (the persistent response history). Each surface has a font
/// size (points), an opacity (0–1), and an on/off enabled flag. Backed by UserDefaults; defaults and
/// clamp bounds come from `Config`. Foundation-only so it stays unit-testable in JarvisCore. Inject a
/// `UserDefaults(suiteName:)` in tests.
public final class OverlayAppearance {
    private let defaults: UserDefaults

    private enum Key {
        static let captionFontSize = "overlayCaption.fontSize"
        static let captionBackgroundOpacity = "overlayCaption.backgroundOpacity"
        static let captionEnabled = "overlayCaption.enabled"
        static let boxFontSize = "overlayBox.fontSize"
        static let boxOpacity = "overlayBox.opacity"
        static let boxEnabled = "overlayBox.enabled"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Overlay Caption (transient on-screen tip)

    public var captionFontSize: Double {
        get {
            guard defaults.object(forKey: Key.captionFontSize) != nil else { return Config.overlayCaptionFontSizeDefault }
            return Self.clamp(defaults.double(forKey: Key.captionFontSize), to: Config.overlayCaptionFontSizeRange)
        }
        set { defaults.set(Self.clamp(newValue, to: Config.overlayCaptionFontSizeRange), forKey: Key.captionFontSize) }
    }

    public var captionBackgroundOpacity: Double {
        get {
            guard defaults.object(forKey: Key.captionBackgroundOpacity) != nil else { return Config.overlayCaptionOpacityDefault }
            return Self.clamp(defaults.double(forKey: Key.captionBackgroundOpacity), to: Config.overlayCaptionOpacityRange)
        }
        set { defaults.set(Self.clamp(newValue, to: Config.overlayCaptionOpacityRange), forKey: Key.captionBackgroundOpacity) }
    }

    /// Whether the caption shows coaching tips on screen. Off by default.
    public var captionEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.captionEnabled) != nil else { return Config.overlayCaptionEnabledDefault }
            return defaults.bool(forKey: Key.captionEnabled)
        }
        set { defaults.set(newValue, forKey: Key.captionEnabled) }
    }

    // MARK: - Overlay Box (persistent response history)

    /// Point size of the box's response text.
    public var boxFontSize: Double {
        get {
            guard defaults.object(forKey: Key.boxFontSize) != nil else { return Config.overlayBoxFontSizeDefault }
            return Self.clamp(defaults.double(forKey: Key.boxFontSize), to: Config.overlayBoxFontSizeRange)
        }
        set { defaults.set(Self.clamp(newValue, to: Config.overlayBoxFontSizeRange), forKey: Key.boxFontSize) }
    }

    /// Opacity (0–1) of the box's background fill.
    public var boxOpacity: Double {
        get {
            guard defaults.object(forKey: Key.boxOpacity) != nil else { return Config.overlayBoxOpacityDefault }
            return Self.clamp(defaults.double(forKey: Key.boxOpacity), to: Config.overlayBoxOpacityRange)
        }
        set { defaults.set(Self.clamp(newValue, to: Config.overlayBoxOpacityRange), forKey: Key.boxOpacity) }
    }

    /// Whether the persistent box is shown. On by default.
    public var boxEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.boxEnabled) != nil else { return Config.overlayBoxEnabledDefault }
            return defaults.bool(forKey: Key.boxEnabled)
        }
        set { defaults.set(newValue, forKey: Key.boxEnabled) }
    }

    /// Clamp into `r`. Non-finite input (NaN/±inf — e.g. a corrupted plist value) falls back to the
    /// lower bound rather than propagating to `systemFont(ofSize:)` / `withAlphaComponent(:)`.
    private static func clamp(_ v: Double, to r: ClosedRange<Double>) -> Double {
        guard v.isFinite else { return r.lowerBound }
        return min(max(v, r.lowerBound), r.upperBound)
    }
}

/// How a settings panel pushes live changes to the Overlay Caption without depending on AppKit. The
/// real `OverlayCaptionPanel` (in JarvisApp's overlay target) conforms; tests can supply a fake.
@MainActor
public protocol OverlayCaptionApplying: AnyObject {
    func setFontSize(_ points: Double)
    func setBackgroundOpacity(_ opacity: Double)
    /// Turn the caption on or off live. When off, coaching tips are suppressed; the live preview still
    /// works so size/opacity stay adjustable.
    func setEnabled(_ enabled: Bool)
    /// Show a sample tip (on) or clear it (off) so size/opacity changes are visible while the
    /// settings window is open. Must preserve screen-capture exclusion.
    func showAppearancePreview(_ on: Bool)
}

/// How a settings panel pushes live changes to the Overlay Box, without depending on AppKit. The real
/// `OverlayBoxPanel` (in the overlay target) conforms; tests can supply a fake.
@MainActor
public protocol OverlayBoxApplying: AnyObject {
    func setOpacity(_ opacity: Double)
    func setFontSize(_ points: Double)
    /// Show or hide the box live, mirroring the persisted setting.
    func setEnabled(_ enabled: Bool)
    /// Show the box with sample text (on) or restore the real log and prior visibility (off) so size
    /// and opacity changes are visible while the settings window is open. Must preserve capture exclusion.
    func showAppearancePreview(_ on: Bool)
}
