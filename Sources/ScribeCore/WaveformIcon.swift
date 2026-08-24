import AppKit

/// Scribe's mark: four rounded bars, a waveform.
///
/// Drawn rather than shipped as an asset, because the menu bar needs it in
/// several poses (idle, live level, muted) and generating them from one set of
/// proportions keeps them identical in weight.
///
/// The source design is an 18×16 box with 3-wide capsule bars on a 5pt pitch,
/// heights 6 / 16 / 10 / 6, all at full strength. Every bar is centred on the
/// same axis, which is what makes the level-driven pose work: only the heights
/// change, and the mark keeps its shape.
///
/// In Core rather than next to the menu bar view because it is plain AppKit
/// drawing with no SwiftUI in it, which makes its geometry testable.
///
/// Main actor because it is AppKit drawing with a cache behind it. That is not
/// a formality: the cache was briefly a `nonisolated(unsafe)` dictionary, and
/// two threads calling `live(level:)` at once corrupted it and aborted the
/// process. The only caller is a SwiftUI body, which is already here.
@MainActor
public enum WaveformIcon {

    // MARK: Design

    /// The box the proportions are defined in.
    static let designSize = CGSize(width: 18, height: 16)
    static let barWidth: CGFloat = 3
    static let pitch: CGFloat = 5
    static let restingHeights: [CGFloat] = [6, 16, 10, 6]

    /// Rendered height in points.
    ///
    /// 15, not the design's 16: the menu bar gives an icon about 16pt of room
    /// once its own padding is taken out, and a mark that fills every one of
    /// them sits taller than the system items either side of it.
    static let renderedHeight: CGFloat = 15

    private static var scale: CGFloat { renderedHeight / designSize.height }

    static var renderedSize: CGSize {
        CGSize(width: (designSize.width * scale).rounded(),
               height: renderedHeight)
    }

    // MARK: Poses

    /// The mark as drawn — the idle icon.
    public static let resting: NSImage = render(heights: restingHeights)

    /// The mark dimmed, for when Scribe cannot actually hear its shortcut.
    ///
    /// Dimmed rather than collapsed: flattening the bars turns the mark into
    /// four dots that read as "…" — a progress indicator, not a disabled one —
    /// and throws away the silhouette that makes it recognisable. Greying out
    /// is the idiom every other menu bar item uses for the same thing.
    public static let muted: NSImage = {
        let image = render(heights: restingHeights, opacity: 0.35)
        image.accessibilityDescription = "Scribe — permissions needed"
        return image
    }()

    /// The mark driven by the live input level.
    ///
    /// The level is quantised before it reaches here, so a steady voice reuses
    /// one cached image instead of redrawing the menu bar 30 times a second.
    public static func live(level: Float) -> NSImage {
        let step = max(0, min(levelSteps, Int((level * Float(levelSteps)).rounded())))
        if let cached = liveCache[step] { return cached }

        let fraction = CGFloat(step) / CGFloat(levelSteps)
        // Each bar keeps its share of the design's silhouette, so the mark
        // reads as itself at every level rather than as four equal bars.
        let heights = restingHeights.map { resting -> CGFloat in
            let floor = barWidth                     // a capsule at its minimum
            let ceiling = resting
            return floor + (ceiling - floor) * fraction
        }
        let image = render(heights: heights)
        image.accessibilityDescription = "Scribe — listening"
        liveCache[step] = image
        return image
    }

    static let levelSteps = 8
    private static var liveCache: [Int: NSImage] = [:]

    // MARK: Drawing

    static func render(heights: [CGFloat], opacity: CGFloat = 1) -> NSImage {
        let size = renderedSize
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.withAlphaComponent(opacity).setFill()
            for (index, height) in heights.enumerated() {
                let clamped = max(barWidth, min(designSize.height, height))
                // Every bar shares one centre line, so a pose only changes
                // heights — never the baseline.
                let rect = CGRect(
                    x: CGFloat(index) * pitch * scale,
                    y: (designSize.height - clamped) / 2 * scale,
                    width: barWidth * scale,
                    height: clamped * scale)

                // A capsule at any height: radius is half the width, which is
                // what rx="1.5" on a 3-wide bar means.
                NSBezierPath(roundedRect: rect,
                             xRadius: rect.width / 2,
                             yRadius: rect.width / 2).fill()
            }
            return true
        }

        // Template, so the menu bar tints it: black on a light bar, white on a
        // dark one, and inverted while the menu is open. The colour above is
        // only ever a mask.
        image.isTemplate = true
        image.accessibilityDescription = "Scribe"
        return image
    }
}
