import AppKit

/// Clio's mark: four rounded bars, a waveform.
///
/// Drawn rather than shipped as an asset, because the menu bar needs it in
/// several poses (idle, live level, muted) and generating them from one set of
/// proportions keeps them identical in weight.
///
/// The source design is a 211×164 box of 35.14-wide capsules on a 58.57 pitch.
/// Four columns, and the third is split: a dot high and a bar low, which is
/// the thing that makes the mark read as a waveform rather than a bar chart.
/// Only that column is off the centre line, and it is off it deliberately.
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
    static let designSize = CGSize(width: 211, height: 164)
    static let barWidth: CGFloat = 35.1429
    static let pitch: CGFloat = 58.5714

    /// One capsule of the mark, in the drawing's own coordinates.
    ///
    /// `y` is measured from the BOTTOM, unlike the SVG it came from. Every
    /// element used to sit on one centre line so the flip did not matter; the
    /// split column means it does now, and getting it wrong puts the dot
    /// underneath the bar.
    struct Bar: Equatable {
        var x: CGFloat
        var y: CGFloat
        var height: CGFloat

        var centre: CGFloat { y + height / 2 }
    }

    /// Converted from the SVG's top-down y once, here, rather than at every
    /// use: y_bottom = 164 − y_svg − height.
    static let bars: [Bar] = [
        Bar(x: 0,        y: 46.8569,  height: 70.2857),   // svg y 46.8574
        Bar(x: 58.5723,  y: 0,        height: 164),       // svg y 0
        Bar(x: 117.143,  y: 111.2858, height: 35.1429),   // svg y 17.5713 — the dot
        Bar(x: 117.143,  y: 17.5717,  height: 70.2857),   // svg y 76.1426
        Bar(x: 175.715,  y: 46.8569,  height: 70.2857),   // svg y 46.8574
    ]

    /// Rendered height in points.
    ///
    /// The menu bar gives an icon about 16pt of room once its own padding is
    /// taken out, and a mark that fills every one of them sits taller than the
    /// system items either side of it.
    static let renderedHeight: CGFloat = 15

    private static var scale: CGFloat { renderedHeight / designSize.height }

    static var renderedSize: CGSize {
        // Rounded UP. The outer capsules sit flush against the edges of the
        // drawing, so rounding down shaves a sliver off the last one and it
        // renders with a flat outer end instead of a round one.
        CGSize(width: (designSize.width * scale).rounded(.up),
               height: renderedHeight)
    }

    // MARK: Poses

    /// The mark as drawn — the idle icon.
    public static let resting: NSImage = render(bars: bars)

    /// The mark dimmed, for when Clio cannot actually hear its shortcut.
    ///
    /// Dimmed rather than collapsed: flattening the bars turns the mark into
    /// four dots that read as "…" — a progress indicator, not a disabled one —
    /// and throws away the silhouette that makes it recognisable. Greying out
    /// is the idiom every other menu bar item uses for the same thing.
    public static let muted: NSImage = {
        let image = render(bars: bars, opacity: 0.35)
        image.accessibilityDescription = "Clio — permissions needed"
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
        // Each capsule shrinks toward a circle about ITS OWN centre, not the
        // box's. The split column has to stay split at every level, or the
        // mark collapses into a row of dots on a line and stops being itself.
        let scaled = bars.map { bar -> Bar in
            let floor = barWidth                     // a capsule at its minimum
            let height = floor + (bar.height - floor) * fraction
            return Bar(x: bar.x, y: bar.centre - height / 2, height: height)
        }
        let image = render(bars: scaled)
        image.accessibilityDescription = "Clio — listening"
        liveCache[step] = image
        return image
    }

    static let levelSteps = 8
    private static var liveCache: [Int: NSImage] = [:]

    // MARK: Drawing

    static func render(bars: [Bar], opacity: CGFloat = 1) -> NSImage {
        let size = renderedSize
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.withAlphaComponent(opacity).setFill()
            for bar in bars {
                let rect = CGRect(x: bar.x * scale,
                                  y: bar.y * scale,
                                  width: barWidth * scale,
                                  height: bar.height * scale)
                // A capsule at any height: radius is half the width, which is
                // what rx="17.57" on a 35.14-wide bar means.
                NSBezierPath(roundedRect: rect,
                             xRadius: rect.width / 2,
                             yRadius: rect.width / 2).fill()
            }
            return true
        }

        image.isTemplate = true
        image.accessibilityDescription = "Clio"
        return image
    }
}
