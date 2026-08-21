import Foundation

/// Persisted overlay appearance for both overlay surfaces — the Overlay Caption (the transient
/// on-screen tip) and the Overlay Box (the persistent response history). Each surface has a font
/// size (points), an opacity (0–1), and an on/off enabled flag. Backed by UserDefaults; every key,
/// default, and clamp bound comes from `Defaults.Overlay`. Foundation-only so it stays unit-testable
/// in JarvisCore. Inject a `UserDefaults(suiteName:)` in tests.
public final class OverlayAppearance {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Overlay Caption (transient on-screen tip)

    public var captionFontSize: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Caption.fontSizeKey) != nil else {
                return Defaults.Overlay.Caption.fontSize
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Caption.fontSizeKey),
                to: Defaults.Overlay.Caption.fontSizeRange)
        }
        set {
            defaults.set(
                Self.clamp(newValue, to: Defaults.Overlay.Caption.fontSizeRange),
                forKey: Defaults.Overlay.Caption.fontSizeKey)
        }
    }

    public var captionBackgroundOpacity: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Caption.opacityKey) != nil else {
                return Defaults.Overlay.Caption.opacity
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Caption.opacityKey),
                to: Defaults.Overlay.Caption.opacityRange)
        }
        set {
            defaults.set(
                Self.clamp(newValue, to: Defaults.Overlay.Caption.opacityRange),
                forKey: Defaults.Overlay.Caption.opacityKey)
        }
    }

    /// Whether the caption shows coaching tips on screen. Off by default.
    public var captionEnabled: Bool {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Caption.enabledKey) != nil else {
                return Defaults.Overlay.Caption.enabled
            }
            return defaults.bool(forKey: Defaults.Overlay.Caption.enabledKey)
        }
        set { defaults.set(newValue, forKey: Defaults.Overlay.Caption.enabledKey) }
    }

    // MARK: - Overlay Box (persistent response history)

    /// Point size of the box's response text.
    public var boxFontSize: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Box.fontSizeKey) != nil else {
                return Defaults.Overlay.Box.fontSize
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Box.fontSizeKey),
                to: Defaults.Overlay.Box.fontSizeRange)
        }
        set {
            defaults.set(
                Self.clamp(newValue, to: Defaults.Overlay.Box.fontSizeRange),
                forKey: Defaults.Overlay.Box.fontSizeKey)
        }
    }

    /// Opacity (0–1) of the box's background fill.
    public var boxOpacity: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Box.opacityKey) != nil else {
                return Defaults.Overlay.Box.opacity
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Box.opacityKey),
                to: Defaults.Overlay.Box.opacityRange)
        }
        set {
            defaults.set(
                Self.clamp(newValue, to: Defaults.Overlay.Box.opacityRange),
                forKey: Defaults.Overlay.Box.opacityKey)
        }
    }

    /// Width in points of the box, as the user last dragged it.
    public var boxWidth: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Box.widthKey) != nil else {
                return Defaults.Overlay.Box.width
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Box.widthKey),
                to: Defaults.Overlay.Box.widthRange)
        }
        set {
            defaults.set(
                Self.clamp(newValue, to: Defaults.Overlay.Box.widthRange),
                forKey: Defaults.Overlay.Box.widthKey)
        }
    }

    /// Height in points of the box, as the user last dragged it.
    public var boxHeight: Double {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Box.heightKey) != nil else {
                return Defaults.Overlay.Box.height
            }
            return Self.clamp(
                defaults.double(forKey: Defaults.Overlay.Box.heightKey),
                to: Defaults.Overlay.Box.heightRange)
        }
        set {
            defaults.set(
                Self.clamp(newValue, to: Defaults.Overlay.Box.heightRange),
                forKey: Defaults.Overlay.Box.heightKey)
        }
    }

    /// Whether the persistent box is shown. On by default.
    public var boxEnabled: Bool {
        get {
            guard defaults.object(forKey: Defaults.Overlay.Box.enabledKey) != nil else {
                return Defaults.Overlay.Box.enabled
            }
            return defaults.bool(forKey: Defaults.Overlay.Box.enabledKey)
        }
        set { defaults.set(newValue, forKey: Defaults.Overlay.Box.enabledKey) }
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
    /// Restore the box to the size the user last dragged it to. Applied once at launch; a
    /// programmatic resize must not read back as a user edit.
    func setContentSize(width: Double, height: Double)
    /// Called once per finished resize drag with the box's new content size, so the app can persist
    /// it. Never fires for `setContentSize(width:height:)`.
    var onSizeChanged: ((Double, Double) -> Void)? { get set }
    /// Show or hide the box live, mirroring the persisted setting.
    func setEnabled(_ enabled: Bool)
    /// Show the box with sample text (on) or restore the real log and prior visibility (off) so size
    /// and opacity changes are visible while the settings window is open. Must preserve capture exclusion.
    func showAppearancePreview(_ on: Bool)
}
