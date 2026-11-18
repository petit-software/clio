import AppKit
import SwiftUI
import ClioCore

/// The library window's glyphs: copy, the ⋯, the sidebar button, search, the
/// chevrons, what a row is — a meeting's calendar or a dictation's
/// transcript — and the notes' to-dos, open and done.
///
/// Drawn from SVG path data, as the Settings tabs are (`SettingsIcon`):
/// the package has no resource bundle. The source files are in
/// Resources/Icon/Library, and the strings below are their `d` attributes,
/// verbatim — paste a new export in and the window follows. All are on a
/// 24-point grid and filled even-odd, as exported.
enum LibraryIcon: Sendable {
    case copy, ellipsis, sidebar, search, calendar, transcript
    case chevronDown, chevronBack, chevronForward
    case todoOpen, todoDone

    /// The glyph in its 24-point box, y down.
    var path: Path { Self.paths[self]! }

    private static let paths: [LibraryIcon: Path] = {
        func parse(_ data: String) -> Path { Path(SVGPath.cgPath(data)) }
        // The files that are strokes, 2 wide with round ends and joins, as
        // outlines, so they fill like every other glyph.
        func stroked(_ data: String) -> Path {
            Path(SVGPath.cgPath(data)
                .copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 10))
        }
        let back = parse(ChevronLeft)
        return [
            .copy: parse(Copy),
            .ellipsis: parse(Ellipsis),
            .sidebar: stroked(Sidebar),
            .search: parse(Search),
            .calendar: parse(CalendarDay),
            .transcript: parse(Transcript),
            .chevronDown: parse(ChevronDown),
            .chevronBack: back,
            // One chevron drawn, the other its mirror, so the day's two
            // arrows cannot drift apart.
            .chevronForward: back.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 24, ty: 0)),
            .todoDone: parse(TodoDone),
            // The file is a circle of radius 9 stroked 2 wide, and SVGPath
            // reads no circles: the same ring, as two filled even-odd.
            .todoOpen: Path { ring in
                ring.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
                ring.addEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
            },
        ]
    }()

    /// The glyph as a template image `size` points square, for AppKit —
    /// the toolbar's sidebar button. Tints as an SF Symbol would.
    @MainActor
    func image(size: CGFloat) -> NSImage {
        let path = self.path.cgPath
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / 24, y: rect.height / 24)
            context.addPath(path)
            context.setFillColor(.black)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Paths — Resources/Icon/Library/*.svg

    private static let Copy = "M18.035265 16.863741Q 17.703831 16.952528 16.940187 16.983461Q 16.838518 18.27721 16.564014 18.815975Q 15.974017 19.974018 14.815956 20.564024Q 13.960268 21 11.2 21L 8.8000002 21Q 6.0396652 21 5.1840153 20.563995Q 4.0259933 19.973999 3.4359689 18.815981Q 3 17.960257 3 15.200001L 3 12.8Q 3 10.039734 3.4359634 9.1840591Q 4.0260119 8.0260143 5.1840415 7.4359722Q 5.7227669 7.1614761 7.0165443 7.0598092Q 7.0474858 6.2961679 7.1362939 5.9647207Q 7.7340078 3.7340248 9.9646864 3.1362927Q 10.47335 3 12 3L 15.200001 3Q 17.960257 3 18.815981 3.4359689Q 19.973999 4.0259933 20.563995 5.1840153Q 21 6.0396652 21 8.8000002L 21 12Q 21 13.526626 20.863722 14.03534Q 20.26598 16.265982 18.035265 16.863741ZM17.517736 14.93186Q 18.633003 14.633005 18.931879 13.517667Q 19 13.263375 19 12L 19 8.8000002Q 19 6.5198545 18.782005 6.0920448Q 18.48698 5.5129795 17.908018 5.2179914Q 17.480143 5 15.200001 5L 12 5Q 10.736649 5 10.482314 5.0681472Q 9.3670044 5.3670053 9.0681458 6.4823589Q 9.0335779 6.611371 9.0165453 7L 11.2 7Q 13.960256 7 14.815953 7.4359541Q 15.973996 8.0259933 16.56402 9.1840668Q 17 10.03972 17 12.8L 17 14.983459Q 17.3887 14.966427 17.517736 14.93186ZM15 12.8Q 15 10.519879 14.78198 10.091993Q 14.486979 9.5129786 13.908048 9.2180052Q 13.480144 9 11.2 9L 8.8000002 9Q 6.5198402 9 6.0920186 9.2179871Q 5.5130067 9.5130072 5.2179971 10.092001Q 5 10.519868 5 12.8L 5 15.200001Q 5 17.480143 5.2179914 17.908018Q 5.5129795 18.48698 6.0920448 18.782005Q 6.5198545 19 8.8000002 19L 11.2 19Q 13.480131 19 13.908045 18.781977Q 14.487006 18.487009 14.781986 17.908024Q 15 17.480129 15 15.2L 15 12.8Z"
    private static let Ellipsis = "M2 12C2 10.8954 2.89543 10 4 10C5.10457 10 6 10.8954 6 12C6 13.1046 5.10457 14 4 14C2.89543 14 2 13.1046 2 12ZM10 12C10 10.8954 10.8954 10 12 10C13.1046 10 14 10.8954 14 12C14 13.1046 13.1046 14 12 14C10.8954 14 10 13.1046 10 12ZM18 12C18 10.8954 18.8954 10 20 10C21.1046 10 22 10.8954 22 12C22 13.1046 21.1046 14 20 14C18.8954 14 18 13.1046 18 12Z"
    /// Strokes in the file, two paths as one string: see `stroked`.
    private static let Sidebar = "M3 8C3 6.34315 4.34315 5 6 5H18C19.6569 5 21 6.34315 21 8V16C21 17.6569 19.6569 19 18 19H6C4.34315 19 3 17.6569 3 16V8Z M7 9V15"
    /// A filled outline in the file — the ring and its handle as one
    /// shape, the lens a second subpath inside it — not strokes.
    private static let Search = "M11 19Q 7.6862931 19 5.3431473 16.656857Q 3 14.313711 2.999999 11Q 2.9999995 7.6862946 5.3431468 5.3431473Q 7.6862941 3 11.000004 2.999999Q 14.313714 2.9999995 16.656858 5.3431473Q 19 7.6862926 19 11.000004Q 19 13.802148 17.324476 15.910263L 20.707108 19.292892Q 20.776752 19.362535 20.83147 19.444427Q 20.886189 19.52632 20.923878 19.617313Q 20.961571 19.708309 20.980785 19.804909Q 21 19.901508 21 20Q 21 20.098492 20.980785 20.195089Q 20.961571 20.291687 20.923878 20.382683Q 20.886189 20.473677 20.83147 20.555569Q 20.776752 20.637463 20.707108 20.707108Q 20.637463 20.776752 20.555569 20.83147Q 20.473677 20.886189 20.382683 20.923878Q 20.291687 20.961571 20.195089 20.980785Q 20.098492 21 20 21Q 19.901508 21 19.804909 20.980785Q 19.708309 20.961571 19.617313 20.923878Q 19.52632 20.886189 19.444427 20.83147Q 19.362535 20.776752 19.292892 20.707108L 15.910263 17.324476Q 13.802146 19 11 19ZM11 17Q 13.485287 17 15.242643 15.242644Q 17 13.485289 17 11.000004Q 17 8.514719 15.242643 6.7573595Q 13.485286 4.999999 11.000004 4.999999Q 8.5147209 5 6.75736 6.7573605Q 4.9999995 8.5147209 4.999999 11Q 5 13.485284 6.7573605 15.242642Q 8.51472 17 11 17Z"
    private static let ChevronDown = "M10.5858 14.0002C11.3668 14.7812 12.6332 14.7812 13.4142 14.0002L16.7071 10.7073C17.0976 10.3167 17.0976 9.68357 16.7071 9.29304C16.3166 8.90252 15.6834 8.90252 15.2929 9.29304L12 12.5859L8.70711 9.29304C8.31658 8.90252 7.68342 8.90252 7.29289 9.29304C6.90237 9.68357 6.90237 10.3167 7.29289 10.7073L10.5858 14.0002Z"
    private static let ChevronLeft = "M14.293 7.29289C13.9025 6.90237 13.2694 6.90237 12.8788 7.29289L9.58594 10.5858C8.80489 11.3668 8.80489 12.6332 9.58594 13.4142L12.8788 16.7071C13.2694 17.0976 13.9025 17.0976 14.293 16.7071C14.6836 16.3166 14.6836 15.6834 14.293 15.2929L11.0002 12L14.293 8.70711C14.6836 8.31658 14.6836 7.68342 14.293 7.29289Z"
    private static let CalendarDay = "M8 2C8.55228 2 9 2.44772 9 3V4H15V3C15 2.44772 15.4477 2 16 2C16.5523 2 17 2.44772 17 3V4H18C19.6569 4 21 5.34315 21 7V18C21 19.6569 19.6569 21 18 21H6C4.34315 21 3 19.6569 3 18V7C3 5.34315 4.34315 4 6 4H7V3C7 2.44772 7.44772 2 8 2ZM7 9C7 8.44772 7.44772 8 8 8H16C16.5523 8 17 8.44772 17 9C17 9.55228 16.5523 10 16 10H8C7.44772 10 7 9.55228 7 9Z"
    private static let TodoDone = "M12 2C17.5228 2 22 6.47715 22 12C22 17.5228 17.5228 22 12 22C6.47715 22 2 17.5228 2 12C2 6.47715 6.47715 2 12 2ZM15.5586 8.1709C15.1005 7.8626 14.4794 7.98355 14.1709 8.44141L10.4727 13.9336L8.70703 12.168C8.31651 11.7774 7.68349 11.7774 7.29297 12.168C6.90244 12.5585 6.90244 13.1915 7.29297 13.582L9.91797 16.207C10.1293 16.4183 10.4243 16.5239 10.7217 16.4951C11.0188 16.4662 11.2873 16.3062 11.4541 16.0586L15.8291 9.55859C16.1374 9.10055 16.0165 8.47937 15.5586 8.1709Z"
    /// Three `<path>`s in the file, one string here; they do not overlap,
    /// so even-odd fills them as the file's non-zero would.
    private static let Transcript = "M21.1213 4.70705C19.9497 3.53548 18.0503 3.53548 16.8787 4.70705L7.87868 13.707C7.31607 14.2697 7 15.0327 7 15.8284V18.9999C7 19.5522 7.44772 19.9999 8 19.9999H11.1716C11.9672 19.9999 12.7303 19.6839 13.2929 19.1213L22.2929 10.1213C23.4645 8.94969 23.4645 7.0502 22.2929 5.87862L21.1213 4.70705Z M2 4.99994C1.44772 4.99994 1 5.44766 1 5.99994C1 6.55223 1.44772 6.99994 2 6.99994H9C9.55228 6.99994 10 6.55223 10 5.99994C10 5.44766 9.55228 4.99994 9 4.99994H2Z M2 8.99994C1.44772 8.99994 1 9.44766 1 9.99994C1 10.5522 1.44772 10.9999 2 10.9999H6C6.55228 10.9999 7 10.5522 7 9.99994C7 9.44766 6.55228 8.99994 6 8.99994H2Z"
}

/// A `LibraryIcon` in SwiftUI, filled with the foreground style.
///
/// `size` is the 24-point box, margins and all, so icons drawn at one size
/// share the grid they were designed on — the rows' calendar and transcript.
/// `cropped` drops the margins and makes `size` the glyph's long side, for a
/// mark that sits in a line of text — the chevrons.
struct Glyph: View {
    let icon: LibraryIcon
    var size: CGFloat
    var cropped = false

    private var box: CGRect {
        cropped ? icon.path.boundingRect : CGRect(x: 0, y: 0, width: 24, height: 24)
    }

    var body: some View {
        let box = box
        let scale = size / max(box.width, box.height)
        GlyphShape(path: icon.path, box: box)
            .fill(style: FillStyle(eoFill: true))
            .frame(width: box.width * scale, height: box.height * scale)
            .accessibilityHidden(true)
    }
}

private struct GlyphShape: Shape {
    let path: Path
    let box: CGRect

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / box.width, rect.height / box.height)
        let transform = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.minX + (rect.width - box.width * scale) / 2,
                                             y: rect.minY + (rect.height - box.height * scale) / 2))
        return path.applying(transform)
    }
}
