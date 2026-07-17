import Foundation

/// Classifies low-resolution screen frames without trusting compositor redraws as user-visible
/// changes. Browsers can continuously produce full-surface frames for an otherwise static page;
/// comparing the actual pixels lets those redraws advance quiescence instead of blocking it.
public struct ScreenFrameActivityClassifier: Sendable {
    public enum ChangeEvidence: Sendable, Equatable {
        case visualPixels
        case boundedDirtyRegion
    }

    public enum Observation: Sendable, Equatable {
        case idle
        case changed(areaRatio: Double, evidence: ChangeEvidence)
    }

    private let minimumChangedAreaRatio: Double
    private let maximumMetadataOnlyAreaRatio: Double
    private let minimumPixelDelta: UInt8
    private var previousPixels: [UInt8]?

    public init(minimumChangedAreaRatio: Double,
                maximumMetadataOnlyAreaRatio: Double = 0.25,
                minimumPixelDelta: UInt8 = 16) {
        precondition((0...1).contains(minimumChangedAreaRatio),
                     "Minimum changed-area ratio must be between zero and one")
        precondition((0...1).contains(maximumMetadataOnlyAreaRatio),
                     "Maximum metadata-only area ratio must be between zero and one")
        self.minimumChangedAreaRatio = minimumChangedAreaRatio
        self.maximumMetadataOnlyAreaRatio = max(
            minimumChangedAreaRatio, maximumMetadataOnlyAreaRatio)
        self.minimumPixelDelta = minimumPixelDelta
    }

    /// `pixels` is one byte of grayscale intensity per pixel from the monitor's already-downscaled
    /// frame. Dirty-region metadata remains useful for tiny edits, but only while it describes a
    /// bounded region. A full-surface dirty rectangle is common compositor behavior and cannot, by
    /// itself, prove that visible content changed.
    public mutating func observe(pixels: [UInt8],
                                 dirtyAreaRatio: Double?) -> Observation {
        precondition(!pixels.isEmpty, "A screen frame must contain pixels")
        if let dirtyAreaRatio {
            precondition((0...1).contains(dirtyAreaRatio),
                         "Dirty-area ratio must be between zero and one")
        }

        guard let previousPixels else {
            self.previousPixels = pixels
            return .idle
        }
        guard previousPixels.count == pixels.count else {
            self.previousPixels = pixels
            return .changed(areaRatio: 1, evidence: .visualPixels)
        }

        var changedPixelCount = 0
        for index in pixels.indices {
            let previous = previousPixels[index]
            let current = pixels[index]
            let delta = previous > current ? previous - current : current - previous
            if delta >= minimumPixelDelta { changedPixelCount += 1 }
        }
        self.previousPixels = pixels

        let pixelRatio = Double(changedPixelCount) / Double(pixels.count)
        if pixelRatio > 0, pixelRatio >= minimumChangedAreaRatio {
            return .changed(areaRatio: pixelRatio, evidence: .visualPixels)
        }

        if let dirtyAreaRatio,
           dirtyAreaRatio > 0,
           dirtyAreaRatio >= minimumChangedAreaRatio,
           dirtyAreaRatio <= maximumMetadataOnlyAreaRatio {
            return .changed(areaRatio: dirtyAreaRatio, evidence: .boundedDirtyRegion)
        }

        return .idle
    }

    public mutating func reset() {
        previousPixels = nil
    }
}
