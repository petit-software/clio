import AppKit
import SwiftUI
import ClioCore

/// The library window's glyphs: copy, the ⋯, the sidebar button, the
/// chevrons, what a row is — a meeting's calendar or a dictation's
/// transcript — and the notes' to-dos, open and done.
///
/// Drawn from SVG path data, as the Settings tabs are (`SettingsIcon`):
/// the package has no resource bundle. The source files are in
/// Resources/Icon/Library, and the strings below are their `d` attributes,
/// verbatim — paste a new export in and the window follows. All are on a
/// 24-point grid and filled even-odd, as exported.
enum LibraryIcon: Sendable {
    case copy, ellipsis, sidebar, calendar, transcript
    case chevronDown, chevronBack, chevronForward
    case todoOpen, todoDone

    /// The glyph in its 24-point box, y down.
    var path: Path { Self.paths[self]! }

    private static let paths: [LibraryIcon: Path] = {
        func parse(_ data: String) -> Path { Path(SVGPath.cgPath(data)) }
        let back = parse(ChevronLeft)
        return [
            .copy: parse(Copy),
            .ellipsis: parse(Ellipsis),
            .sidebar: parse(Sidebar),
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

    private static let Copy = "M16.8385 3H11.1615C10.6343 2.99998 10.1795 2.99997 9.80497 3.03057C9.40963 3.06287 9.01641 3.13419 8.63803 3.32698C8.07354 3.6146 7.6146 4.07354 7.32698 4.63803C7.13419 5.01641 7.06287 5.40963 7.03057 5.80497C7.00314 6.14076 7.00031 6.54099 7.00003 7.00003C6.54099 7.00031 6.14076 7.00314 5.80497 7.03057C5.40963 7.06287 5.01641 7.13419 4.63803 7.32698C4.07354 7.6146 3.6146 8.07354 3.32698 8.63803C3.13419 9.01641 3.06287 9.40963 3.03057 9.80497C2.99997 10.1795 2.99998 10.6343 3 11.1614V16.8385C2.99998 17.3657 2.99997 17.8205 3.03057 18.195C3.06287 18.5904 3.13419 18.9836 3.32698 19.362C3.6146 19.9265 4.07355 20.3854 4.63803 20.673C5.01641 20.8658 5.40963 20.9371 5.80497 20.9694C6.17952 21 6.63424 21 7.16134 21H12.8385C13.3656 21 13.8205 21 14.195 20.9694C14.5904 20.9371 14.9836 20.8658 15.362 20.673C15.9265 20.3854 16.3854 19.9265 16.673 19.362C16.8658 18.9836 16.9371 18.5904 16.9694 18.195C16.9969 17.8592 16.9997 17.459 17 17C17.459 16.9997 17.8592 16.9969 18.195 16.9694C18.5904 16.9371 18.9836 16.8658 19.362 16.673C19.9265 16.3854 20.3854 15.9265 20.673 15.362C20.8658 14.9836 20.9371 14.5904 20.9694 14.195C21 13.8205 21 13.3658 21 12.8386V7.16148C21 6.63437 21 6.17952 20.9694 5.80497C20.9371 5.40963 20.8658 5.01641 20.673 4.63803C20.3854 4.07354 19.9265 3.6146 19.362 3.32698C18.9836 3.13419 18.5904 3.06287 18.195 3.03057C17.8205 2.99997 17.3657 2.99998 16.8385 3ZM17 14.9999C17.4651 14.9995 17.783 14.9964 18.0322 14.9761C18.3038 14.9539 18.4045 14.9162 18.454 14.891C18.6422 14.7951 18.7951 14.6422 18.891 14.454C18.9162 14.4045 18.9539 14.3038 18.9761 14.0322C18.9992 13.7488 19 13.3766 19 12.8V7.2C19 6.62345 18.9992 6.25118 18.9761 5.96784C18.9539 5.69618 18.9162 5.59546 18.891 5.54601C18.7951 5.35785 18.6422 5.20487 18.454 5.109C18.4045 5.0838 18.3038 5.04613 18.0322 5.02393C17.7488 5.00078 17.3766 5 16.8 5H11.2C10.6234 5 10.2512 5.00078 9.96784 5.02393C9.69618 5.04613 9.59546 5.0838 9.54601 5.109C9.35785 5.20487 9.20487 5.35785 9.109 5.54601C9.0838 5.59546 9.04613 5.69618 9.02393 5.96784C9.00357 6.21698 9.00052 6.5349 9.00007 7H12.8385C13.3657 6.99998 13.8205 6.99997 14.195 7.03057C14.5904 7.06287 14.9836 7.13419 15.362 7.32698C15.9265 7.6146 16.3854 8.07355 16.673 8.63803C16.8658 9.01641 16.9371 9.40963 16.9694 9.80497C17 10.1795 17 10.6343 17 11.1615V14.9999Z"
    private static let Ellipsis = "M2 12C2 10.8954 2.89543 10 4 10C5.10457 10 6 10.8954 6 12C6 13.1046 5.10457 14 4 14C2.89543 14 2 13.1046 2 12ZM10 12C10 10.8954 10.8954 10 12 10C13.1046 10 14 10.8954 14 12C14 13.1046 13.1046 14 12 14C10.8954 14 10 13.1046 10 12ZM18 12C18 10.8954 18.8954 10 20 10C21.1046 10 22 10.8954 22 12C22 13.1046 21.1046 14 20 14C18.8954 14 18 13.1046 18 12Z"
    private static let Sidebar = "M19 4C20.6569 4 22 5.34315 22 7V17C22 18.6569 20.6569 20 19 20H5C3.34315 20 2 18.6569 2 17V7C2 5.34315 3.34315 4 5 4H19ZM7 8C6.44772 8 6 8.44772 6 9V15C6 15.5523 6.44772 16 7 16C7.55228 16 8 15.5523 8 15V9C8 8.44772 7.55228 8 7 8Z"
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
