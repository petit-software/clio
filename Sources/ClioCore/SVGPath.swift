import CoreGraphics
import Foundation

/// The `d` attribute of an SVG `<path>`, as a CGPath.
///
/// Enough of the grammar for what an icon editor exports: moves, lines,
/// horizontals, verticals, cubic curves and closes, absolute or relative,
/// with the implicit line-to after a move. Anything else is a programmer
/// error — the data is ours, embedded in the source and checked by the tests
/// — so it stops rather than drawing something subtly wrong.
///
/// Coordinates come out exactly as written: y down, in the SVG's own units.
/// Whoever draws the result flips and scales it.
public enum SVGPath {

    public static func cgPath(_ data: String) -> CGPath {
        let path = CGMutablePath()
        let tokens = tokenize(data)
        var index = 0
        var command: Character?
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        func number() -> CGFloat {
            precondition(index < tokens.count, "SVG path ends mid-command")
            guard let value = Double(tokens[index]) else {
                preconditionFailure("SVG path: expected a number, found \(tokens[index])")
            }
            index += 1
            return CGFloat(value)
        }

        while index < tokens.count {
            if let letter = tokens[index].first, letter.isLetter {
                command = letter
                index += 1
                if letter == "Z" || letter == "z" {
                    path.closeSubpath()
                    current = subpathStart
                    command = nil
                    continue
                }
            }
            guard let letter = command else {
                preconditionFailure("SVG path: coordinates with no command")
            }
            let relative = letter.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch letter.uppercased() {
            case "M":
                let to = point(number(), number())
                path.move(to: to)
                current = to
                subpathStart = to
                // Further pairs after a move are lines, per the spec.
                command = relative ? "l" : "L"
            case "L":
                let to = point(number(), number())
                path.addLine(to: to)
                current = to
            case "H":
                let x = number()
                let to = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: to)
                current = to
            case "V":
                let y = number()
                let to = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: to)
                current = to
            case "C":
                let control1 = point(number(), number())
                let control2 = point(number(), number())
                let to = point(number(), number())
                path.addCurve(to: to, control1: control1, control2: control2)
                current = to
            default:
                preconditionFailure("SVG path: unsupported command \(letter)")
            }
        }
        return path
    }

    /// Command letters and numbers, in order. Separators — whitespace and
    /// commas — are dropped, and a minus sign starts a new number even with
    /// nothing before it, which is how exporters pack "10-5".
    static func tokenize(_ data: String) -> [String] {
        let pattern = #"[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(data.startIndex..., in: data)
        return regex.matches(in: data, range: range).map {
            String(data[Range($0.range, in: data)!])
        }
    }
}
