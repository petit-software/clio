import Testing
import AppKit
import AVFoundation
@testable import ClioCore

private let dumpEnabled = ProcessInfo.processInfo.environment["CLIO_METER_DUMP"] != nil

/// Run a recording through the meter and draw what it would have shown.
///
///     CLIO_METER_DUMP=/tmp/meter CLIO_METER_VOICE=voice.wav \
///         swift test --filter MeterDumpTests
///
/// Writes a filmstrip of the bars at 30 Hz, a trace of each bar over time,
/// and a CSV, and prints how jumpy each bar was and how much of its range
/// it used. This exists because a meter cannot be judged from a still and
/// was shipped twice without being watched; the strip is the watching.
@MainActor
@Suite("Meter dump", .enabled(if: dumpEnabled))
struct MeterDumpTests {

    private var outputDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLIO_METER_DUMP"]!)
    }

    @Test("Filmstrip and trace of a recording")
    func dump() throws {
        let path = try #require(ProcessInfo.processInfo.environment["CLIO_METER_VOICE"])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: file.fileFormat.sampleRate,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let rate = format.sampleRate
        let frames = Int(buffer.frameLength)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: frames)

        // Through the analyzer buffer by buffer, as the tap would; sampled
        // at 30 Hz, as the timer does.
        let analyzer = MeterAnalyzer()
        let chunk = MeterAnalyzer.length
        var perChunk: [(time: Double, bars: [Float])] = []
        var offset = 0
        while offset + chunk <= frames {
            let slice = UnsafeBufferPointer(rebasing: samples[offset..<offset + chunk])
            let bars = analyzer.process(slice, sampleRate: rate, dt: Float(Double(chunk) / rate))
            perChunk.append((Double(offset + chunk) / rate, bars))
            offset += chunk
        }
        var frames30: [[Float]] = []
        var t = 0.0
        var i = 0
        while t < Double(frames) / rate {
            while i + 1 < perChunk.count, perChunk[i + 1].time <= t { i += 1 }
            frames30.append(perChunk[i].bars)
            t += 1.0 / 30
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try writeCSV(frames30)
        try write(filmstrip(frames30), "filmstrip.png")
        try write(trace(frames30), "trace.png")
        report(frames30)
    }

    // MARK: Drawing

    private static let weights: [CGFloat] = [0.46, 0.76, 0.32, 0.56, 0.32]

    /// One cell per 30 Hz frame, 30 per row: a second per row.
    private func filmstrip(_ frames: [[Float]]) -> NSImage {
        let cell = CGSize(width: 44, height: 52)
        let columns = 30
        let rows = (frames.count + columns - 1) / columns
        let image = NSImage(size: NSSize(width: cell.width * CGFloat(columns),
                                         height: cell.height * CGFloat(rows)))
        image.lockFocus()
        NSColor(white: 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()
        for (index, bars) in frames.enumerated() {
            let column = index % columns
            let row = rows - 1 - index / columns
            let origin = CGPoint(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height)
            if column % 2 == 0 {
                NSColor(white: 0.94, alpha: 1).setFill()
                NSRect(origin: origin, size: cell).fill()
            }
            drawBars(bars, in: NSRect(origin: origin, size: cell), height: 40)
        }
        image.unlockFocus()
        return image
    }

    private func drawBars(_ bars: [Float], in rect: NSRect, height: CGFloat) {
        let barWidth = height * 0.104
        let total = barWidth * 9   // 5 bars, 4 gaps of a bar's width
        var x = rect.midX - total / 2
        NSColor.black.setFill()
        for (index, weight) in Self.weights.enumerated() {
            let full = height * weight
            let h = barWidth + (full - barWidth) * CGFloat(bars[index])
            let bar = NSRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth * 2
        }
    }

    /// Five traces over time, one colour each, on a 30 Hz grid.
    private func trace(_ frames: [[Float]]) -> NSImage {
        let width = CGFloat(max(frames.count, 1)) * 3
        let height: CGFloat = 220
        let image = NSImage(size: NSSize(width: width, height: height * 5))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        let colours: [NSColor] = [.systemBlue, .black, .systemOrange, .systemGreen, .systemPurple]
        for bar in 0..<5 {
            let base = height * CGFloat(4 - bar)
            NSColor(white: 0.9, alpha: 1).setStroke()
            NSBezierPath(rect: NSRect(x: 0, y: base, width: width, height: height)).stroke()
            let path = NSBezierPath()
            for (i, bars) in frames.enumerated() {
                let point = CGPoint(x: CGFloat(i) * 3, y: base + 10 + CGFloat(bars[bar]) * (height - 20))
                i == 0 ? path.move(to: point) : path.line(to: point)
            }
            colours[bar].setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        image.unlockFocus()
        return image
    }

    // MARK: Numbers

    private func report(_ frames: [[Float]]) {
        var lines = ["bar  used-range(p5..p95)  jump/frame  frames>0.5"]
        for bar in 0..<5 {
            let values = frames.map { $0[bar] }.sorted()
            let p5 = values[Int(Double(values.count) * 0.05)]
            let p95 = values[Int(Double(values.count) * 0.95)]
            var jumps: Float = 0
            for i in 1..<frames.count { jumps += abs(frames[i][bar] - frames[i - 1][bar]) }
            let loud = frames.filter { $0[bar] > 0.5 }.count
            lines.append(String(format: "%d    %.2f..%.2f            %.3f       %d/%d",
                                bar, p5, p95, jumps / Float(frames.count - 1), loud, frames.count))
        }
        // How alike the bars are: the mean pairwise correlation.
        var sum = 0.0, pairs = 0
        for a in 0..<5 { for b in (a + 1)..<5 {
            sum += correlation(frames.map { Double($0[a]) }, frames.map { Double($0[b]) }); pairs += 1
        } }
        lines.append(String(format: "mean pairwise correlation %.2f", sum / Double(pairs)))
        let text = lines.joined(separator: "\n")
        print(text)
        try? text.write(to: outputDirectory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var cov = 0.0, va = 0.0, vb = 0.0
        for i in 0..<a.count { cov += (a[i] - ma) * (b[i] - mb); va += (a[i] - ma) * (a[i] - ma); vb += (b[i] - mb) * (b[i] - mb) }
        return va > 0 && vb > 0 ? cov / (va * vb).squareRoot() : 0
    }

    private func writeCSV(_ frames: [[Float]]) throws {
        let rows = frames.enumerated().map { i, bars in
            ([String(format: "%.3f", Double(i) / 30)] + bars.map { String(format: "%.3f", $0) }).joined(separator: ",")
        }
        try (["t,b0,b1,b2,b3,b4"] + rows).joined(separator: "\n")
            .write(to: outputDirectory.appendingPathComponent("bars.csv"), atomically: true, encoding: .utf8)
    }

    private func write(_ image: NSImage, _ name: String) throws {
        let rep = try #require(NSBitmapImageRep(data: image.tiffRepresentation!))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent(name))
    }
}
