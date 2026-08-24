import SwiftUI

/// How solid the dictation pill's surface is.
///
/// Two dials rather than one, because they are not the same effect. `opacity`
/// is how much tint sits over the glass; `isClear` swaps the glass itself for
/// a far more transparent variant. Turning the opacity to zero still leaves a
/// frosted blur — only clear glass removes it.
public struct PillSurface: Codable, Sendable, Equatable {
    /// 0 is bare glass, 1 the flat surface the design was drawn as.
    public var opacity: Double
    public var isClear: Bool

    public init(opacity: Double = 0.30, isClear: Bool = false) {
        // Clamped here rather than at every call site: a value outside 0…1 from
        // a hand-edited settings file renders an invisible or fully opaque
        // pill, and the control that fixes it is inside a window you can no
        // longer read.
        self.opacity = min(1, max(0, opacity))
        self.isClear = isClear
    }

    /// The macOS 14 path has no glass, only the material ladder. Clear maps to
    /// the thinnest rung, which is the nearest thing it has.
    public var fallbackMaterial: Material {
        isClear ? .ultraThinMaterial : .regularMaterial
    }

    // MARK: Presets

    /// Named surfaces, cheapest to read first. These are what the preview
    /// shows side by side, so a choice can be made by looking rather than by
    /// guessing at numbers.
    public struct Preset: Sendable {
        public let name: String
        public let detail: String
        public let surface: PillSurface
    }

    public static let presets: [Preset] = [
        Preset(name: "Clear",
               detail: "Clear glass, barely tinted — the desktop reads through it",
               surface: PillSurface(opacity: 0.10, isClear: true)),
        Preset(name: "Airy",
               detail: "Frosted, minimal tint",
               surface: PillSurface(opacity: 0.18)),
        Preset(name: "Balanced",
               detail: "Current default — an object of its own, still see-through",
               surface: PillSurface(opacity: 0.30)),
        Preset(name: "Frosted",
               detail: "Backdrop muted to a suggestion",
               surface: PillSurface(opacity: 0.45)),
        Preset(name: "Solid",
               detail: "Close to the flat surface the design was drawn as",
               surface: PillSurface(opacity: 0.70)),
    ]
}
