import Testing
import AppKit
@testable import ClioCore

/// The mark's geometry.
///
/// Its proportions come from a drawing, so the things worth pinning down are
/// the ones a careless edit would silently break: that it stays a template
/// image (or the menu bar stops tinting it), that it fits the space the menu
/// bar gives it, and that every bar stays on one centre line.
@MainActor
@Suite("Waveform icon")
struct WaveformIconTests {

    @Test("The mark is a template image, so the menu bar tints it")
    func isTemplate() {
        #expect(WaveformIcon.resting.isTemplate)
        #expect(WaveformIcon.muted.isTemplate)
        #expect(WaveformIcon.live(level: 0.5).isTemplate)
    }

    @Test("It fits the room the menu bar actually gives an icon")
    func fitsTheMenuBar() {
        let size = WaveformIcon.resting.size
        // The menu bar leaves roughly 16pt once its own padding is out. Taller
        // than that and the mark sits proud of the system items either side.
        #expect(size.height <= 16)
        #expect(size.height >= 13)
        // Aspect follows the 18×16 drawing.
        let aspect = size.width / size.height
        let designAspect = WaveformIcon.designSize.width / WaveformIcon.designSize.height
        #expect(abs(aspect - designAspect) < 0.06)
    }

    @Test("Every pose is the same size, so the menu bar does not shift")
    func posesShareOneSize() {
        let resting = WaveformIcon.resting.size
        #expect(WaveformIcon.muted.size == resting)
        for step in 0...WaveformIcon.levelSteps {
            let level = Float(step) / Float(WaveformIcon.levelSteps)
            #expect(WaveformIcon.live(level: level).size == resting)
        }
    }

    @Test("Three columns sit on the centre line and one is deliberately split")
    func splitColumn() {
        let middle = WaveformIcon.designSize.height / 2
        let columns = Dictionary(grouping: WaveformIcon.bars, by: \.x)
        #expect(columns.count == 4)

        // The split column is the whole character of the mark: a dot above and
        // a bar below, neither on the axis. Centre them and it becomes a bar
        // chart.
        let split = columns.values.first { $0.count == 2 }
        let pair = try! #require(split)
        #expect(pair.allSatisfy { abs($0.centre - middle) > 1 })
        #expect(pair.contains { $0.centre > middle })   // the dot, high
        #expect(pair.contains { $0.centre < middle })   // the bar, low

        // Everything else is centred, which is what lets the level pose change
        // only heights without the mark drifting.
        for column in columns.values where column.count == 1 {
            #expect(abs(column[0].centre - middle) < 0.01)
        }
    }

    @Test("The dot is a circle, so it cannot shrink further")
    func dotIsCircular() {
        let dot = WaveformIcon.bars.min(by: { $0.height < $1.height })!
        #expect(abs(dot.height - WaveformIcon.barWidth) < 0.01)
    }

    @Test("Columns sit on the drawing's pitch without touching")
    func barsDoNotCollide() {
        let xs = Set(WaveformIcon.bars.map(\.x)).sorted()
        #expect(xs.count == 4)
        for (a, b) in zip(xs, xs.dropFirst()) {
            #expect(abs((b - a) - WaveformIcon.pitch) < 0.01)
        }
        // Within a rounding of the box: the export ends at 210.86 of 211.
        #expect(abs((xs.last! + WaveformIcon.barWidth)
                    - WaveformIcon.designSize.width) < 0.2)
        #expect(WaveformIcon.pitch > WaveformIcon.barWidth)   // a real gap
    }

    @Test("The level pose is quantised, so a steady voice reuses one image")
    func levelIsQuantisedAndCached() {
        // Two levels inside the same step must be the identical object, or the
        // menu bar redraws at the recorder's 30 Hz.
        let a = WaveformIcon.live(level: 0.50)
        let b = WaveformIcon.live(level: 0.505)
        #expect(a === b)

        let far = WaveformIcon.live(level: 0.0)
        #expect(a !== far)
    }

    @Test("Out-of-range levels are clamped rather than crashing")
    func levelIsClamped() {
        #expect(WaveformIcon.live(level: -3) === WaveformIcon.live(level: 0))
        #expect(WaveformIcon.live(level: 12) === WaveformIcon.live(level: 1))
    }

    @Test("The mark actually draws ink")
    func drawsSomething() throws {
        let image = WaveformIcon.resting
        let representation = try #require(
            image.representations.first as? NSBitmapImageRep
            ?? NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))

        // Solid ink only: counting every antialiased edge pixel would inflate
        // the figure and stop it meaning anything.
        var inked = 0
        for x in 0..<representation.pixelsWide {
            for y in 0..<representation.pixelsHigh {
                if let colour = representation.colorAt(x: x, y: y),
                   colour.alphaComponent > 0.5 {
                    inked += 1
                }
            }
        }
        let total = representation.pixelsWide * representation.pixelsHigh
        let coverage = Double(inked) / Double(total)
        print("[icon] resting coverage \(coverage)")
        // Five capsules across four columns: a third of the box or so. Nothing
        // would be a blank icon, everything a filled block.
        #expect(coverage > 0.15)
        #expect(coverage < 0.60)
    }
}
