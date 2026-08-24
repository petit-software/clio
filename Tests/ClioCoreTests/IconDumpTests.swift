import Testing
import AppKit
@testable import ClioCore

private let dumpEnabled = ProcessInfo.processInfo.environment["CLIO_ICON_DUMP"] != nil

@MainActor
@Suite("Icon dump", .enabled(if: dumpEnabled))
struct IconDumpTests {

    private var outputDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo
            .environment["CLIO_ICON_DUMP"] ?? NSTemporaryDirectory())
    }

    private func write(_ image: NSImage, _ name: String) throws {
        // Created here rather than relied upon: the caller passes a path, not
        // a directory that necessarily exists yet.
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true)
        let representation = try #require(NSBitmapImageRep(data: image.tiffRepresentation!))
        let png = try #require(representation.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent(name))
    }

    /// Tint a template image, the way the menu bar does.
    ///
    /// Done on a transparent canvas: `.sourceAtop` over an opaque background
    /// would paint the background too, which is exactly the mistake that made
    /// the first dump a black rectangle.
    private func tinted(_ image: NSImage, _ colour: NSColor, scale: CGFloat) -> NSImage {
        let size = NSSize(width: image.size.width * scale,
                          height: image.size.height * scale)
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        image.draw(in: rect)
        colour.set()
        rect.fill(using: .sourceAtop)
        canvas.unlockFocus()
        return canvas
    }

    @Test("Dump the poses and a mock menu bar")
    func dump() throws {
        // 1. The mark, large, to compare against the drawing.
        let ink = tinted(WaveformIcon.resting, .black, scale: 20)
        let big = NSImage(size: ink.size)
        big.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: big.size).fill()
        ink.draw(in: NSRect(origin: .zero, size: big.size))
        big.unlockFocus()
        try write(big, "01-resting-large.png")

        // 2. A mock menu bar: our mark beside real system items, actual size.
        let barHeight: CGFloat = 24
        let scale: CGFloat = 6
        let strip = NSImage(size: NSSize(width: 200 * scale, height: barHeight * scale))
        strip.lockFocus()
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSRect(origin: .zero, size: strip.size).fill()

        var x: CGFloat = 12
        func place(_ image: NSImage) {
            let y = (barHeight - image.size.height) / 2
            let white = tinted(image, .white, scale: scale)
            white.draw(in: NSRect(x: x * scale, y: y * scale,
                                  width: white.size.width,
                                  height: white.size.height))
            x += image.size.width + 16
        }

        for name in ["wifi", "battery.75percent", "magnifyingglass"] {
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                let configured = symbol.withSymbolConfiguration(
                    .init(pointSize: 15, weight: .regular)) ?? symbol
                place(configured)
            }
        }
        place(WaveformIcon.resting)
        place(WaveformIcon.live(level: 0.75))
        place(WaveformIcon.muted)
        strip.unlockFocus()
        try write(strip, "02-menubar-mock.png")

        // 3. Every level pose, so the animation can be judged as a sequence.
        let levels = stride(from: 0.0, through: 1.0, by: 0.125).map { Float($0) }
        let sheetScale: CGFloat = 8
        let cell = WaveformIcon.renderedSize
        let sheet = NSImage(size: NSSize(
            width: (cell.width + 6) * CGFloat(levels.count) * sheetScale,
            height: (cell.height + 6) * sheetScale))
        sheet.lockFocus()
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (index, level) in levels.enumerated() {
            let white = tinted(WaveformIcon.live(level: level), .white, scale: sheetScale)
            white.draw(in: NSRect(x: (CGFloat(index) * (cell.width + 6) + 3) * sheetScale,
                                  y: 3 * sheetScale,
                                  width: white.size.width,
                                  height: white.size.height))
        }
        sheet.unlockFocus()
        try write(sheet, "03-levels.png")

        print("[icon dump] wrote to \(outputDirectory.path)")
    }
}
