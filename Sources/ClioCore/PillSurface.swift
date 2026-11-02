import SwiftUI

/// How solid the dictation pill's surface is.
///
/// Two dials rather than one, because they are not the same effect. `opacity`
/// is how much tint sits over the glass; `isClear` swaps the glass itself for
/// a far more transparent variant. Turning the opacity to zero still leaves a
/// frosted blur — only clear glass removes it.
public struct PillSurface: Sendable, Equatable {
    /// 0 is bare glass, 1 the flat surface the design was drawn as.
    public var opacity: Double
    public var isClear: Bool
    /// Tint and hairline, per appearance.
    public var style: PillStyle

    /// The defaults are the shipped look, settled on screen: clear glass at
    /// half opacity. None of it is a setting any more.
    public init(opacity: Double = 0.5, isClear: Bool = true,
                style: PillStyle = .standard) {
        // Clamped here rather than at every call site: a value outside 0…1
        // renders an invisible or fully opaque pill.
        self.opacity = min(1, max(0, opacity))
        self.isClear = isClear
        self.style = style
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
        Preset(name: "Shipped",
               detail: "Clear glass at half opacity — what the app draws",
               surface: PillSurface()),
        Preset(name: "Clear",
               detail: "Clear glass, barely tinted — the desktop reads through it",
               surface: PillSurface(opacity: 0.10, isClear: true)),
        Preset(name: "Airy",
               detail: "Frosted, minimal tint",
               surface: PillSurface(opacity: 0.18, isClear: false)),
        Preset(name: "Balanced",
               detail: "An object of its own, still clearly see-through",
               surface: PillSurface(opacity: 0.30, isClear: false)),
        Preset(name: "Frosted",
               detail: "Backdrop muted to a suggestion",
               surface: PillSurface(opacity: 0.45, isClear: false)),
        Preset(name: "Solid",
               detail: "Close to the flat surface the design was drawn as",
               surface: PillSurface(opacity: 0.70, isClear: false)),
    ]
}

/// The glass tint and the hairline round the pill, per appearance.
///
/// Design constants, not settings: tuned on screen with controls that have
/// since been taken out, and these are the values that came of it. Over
/// claro's starting point (3682504) the dark tint is lighter, so clear glass
/// reads as see-through, and the hairline is fainter but a full point wide.
public struct PillStyle: Sendable, Equatable {
    /// False: the pill is always drawn as it is in dark mode, whatever the
    /// system appearance. Light glass is a milky white that sits on dark
    /// content like haze; the dark pill reads as see-through over anything.
    /// True gives light mode the light values below.
    public var followsSystemAppearance = false
    /// Opacity of the white tint over the glass, light appearance.
    public var glassTintLight = 0.84
    /// Opacity of the black tint over the glass, dark appearance.
    public var glassTintDark = 0.50
    /// Opacity of the black hairline, light appearance.
    public var outlineLight = 0.20
    /// Opacity of the white hairline, dark appearance.
    public var outlineDark = 0.15
    /// In points, at every pill size.
    public var outlineWidth = 1.0

    public static let standard = PillStyle()

    public init() {}
}
