import Testing
import CoreGraphics
@testable import ClioCore

@Suite("SVG paths")
struct SVGPathTests {

    private func box(_ data: String) -> CGRect { SVGPath.cgPath(data).boundingBoxOfPath }

    @Test("Absolute moves, lines, horizontals, verticals and closes")
    func absolute() {
        let path = SVGPath.cgPath("M1 1L5 1V4H1Z")
        #expect(box("M1 1L5 1V4H1Z") == CGRect(x: 1, y: 1, width: 4, height: 3))
        #expect(path.contains(CGPoint(x: 3, y: 2)))
        #expect(!path.contains(CGPoint(x: 0, y: 0)))
    }

    @Test("Relative commands build on the current point")
    func relative() {
        #expect(box("m1 1 l4 0 v3 h-4 z") == CGRect(x: 1, y: 1, width: 4, height: 3))
    }

    @Test("Pairs after a move are lines, per the spec")
    func implicitLines() {
        #expect(box("M0 0 10 0 10 5Z") == CGRect(x: 0, y: 0, width: 10, height: 5))
    }

    @Test("Packed numbers, commas and exponents tokenize")
    func tokens() {
        #expect(SVGPath.tokenize("M10-5.5,.25e1L1e-2 3") == ["M", "10", "-5.5", ".25e1", "L", "1e-2", "3"])
    }

    @Test("A real export: the About glyph fills its 24-box to the 1pt margin")
    func aboutGlyph() {
        let about = "M12 1C18.0751 1 23 5.92487 23 12C23 18.0751 18.0751 23 12 23C5.92487 23 1 18.0751 1 12C1 5.92487 5.92487 1 12 1ZM12 11.5C11.4477 11.5 11 11.9477 11 12.5V16.5C11 17.0523 11.4477 17.5 12 17.5C12.5523 17.5 13 17.0523 13 16.5V12.5C13 11.9477 12.5523 11.5 12 11.5ZM12 6.5C11.1716 6.5 10.5 7.17157 10.5 8C10.5 8.82843 11.1716 9.5 12 9.5C12.8284 9.5 13.5 8.82843 13.5 8C13.5 7.17157 12.8284 6.5 12 6.5Z"
        let path = SVGPath.cgPath(about)
        let bounds = path.boundingBoxOfPath
        #expect(abs(bounds.minX - 1) < 0.01 && abs(bounds.minY - 1) < 0.01)
        #expect(abs(bounds.maxX - 23) < 0.01 && abs(bounds.maxY - 23) < 0.01)
        // The "i" is a hole, so the ring is filled and the stem is not.
        #expect(path.contains(CGPoint(x: 12, y: 2), using: .winding))
        #expect(!path.contains(CGPoint(x: 12, y: 14), using: .winding))
        #expect(!path.contains(CGPoint(x: 12, y: 8), using: .winding))
    }
}
