#if DEBUG
import AppKit
import SwiftUI
import ClioCore

/// Renders the pill in each state to PNGs, so the design can be checked
/// against the drawing it came from rather than eyeballed in a running app —
/// where reaching the error state means causing an error.
///
///     CLIO_OVERLAY_DUMP=/tmp/overlay swift run Clio
@MainActor
public enum OverlayDump {

    /// Put the real panel on screen in one state and leave it there.
    ///
    /// Glass and materials sample what is behind the window, and ImageRenderer
    /// has nothing behind it — it draws them flat. So the surface can only be
    /// judged honestly on screen, and this gets it there without starting a
    /// recording and opening the microphone to do it.
    ///
    ///     CLIO_OVERLAY_SHOW=recording swift run Clio
    ///     CLIO_OVERLAY_SHOW=sequence CLIO_OVERLAY_POSITION=bottomLeft swift run Clio
    ///
    /// `sequence` walks a whole dictation — listening, transcribing, pasting,
    /// copied, gone, then an error — on a loop, which is the only way to
    /// judge the transitions: a still of any one state says nothing about
    /// how it arrived. `CLIO_OVERLAY_POSITION` takes an OverlayPosition raw
    /// value and applies to both. `CLIO_OVERLAY_SIZE` takes a PillSize raw
    /// value (`large`, `extraLarge`) for a single state.
    @discardableResult
    public static func show(state named: String) -> OverlayController {
        // Forced on this app only, so the dark appearance can be judged
        // without flipping the whole system to look at a pill.
        // Non-empty, not merely present: an exported-but-empty variable is
        // how a shell loop sets "off", and != nil treats that as on.
        if ProcessInfo.processInfo.environment["CLIO_OVERLAY_DARK"]?.isEmpty == false {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        let controller = OverlayController()
        let position = ProcessInfo.processInfo.environment["CLIO_OVERLAY_POSITION"]
            .flatMap(OverlayPosition.init(rawValue:)) ?? .topCenter
        if named == "sequence" {
            runSequence(controller, at: position)
            return controller
        }
        // Exercises the real preview path, auto-hide included.
        if named == "preview" {
            controller.showPreview(at: .bottomRight, surface: PillSurface())
            return controller
        }
        let state: DictationState
        switch named {
        case "transcribing": state = .transcribing
        case "error": state = .failed("Nothing returned")
        case "finished": state = .finished("Hello")
        case "copied":
            state = .finished("Hello")
            controller.model.transcriptIsOnClipboard = true
        default: state = .recording
        }
        controller.model.level = 0.75
        controller.model.captureIsLive = true
        if let raw = ProcessInfo.processInfo.environment["CLIO_OVERLAY_OPACITY"],
           let value = Double(raw) {
            controller.model.surface = PillSurface(opacity: value)
        }
        if let size = ProcessInfo.processInfo.environment["CLIO_OVERLAY_SIZE"]
            .flatMap(PillSize.init(rawValue:)) {
            controller.model.size = size
        }
        controller.update(state: state)
        controller.updateProgress(elapsed: 4, limit: 600)
        let mark = ContinuousClock.now
        controller.show(position: position)
        let ms = Double((ContinuousClock.now - mark).components.attoseconds) / 1e15
        // stderr: unbuffered, so the number survives the process being killed.
        FileHandle.standardError.write(Data(
            String(format: "[overlay show] window on screen in %.1f ms\n", ms).utf8))
        if let frame = controller.panelFrame, let screen = NSScreen.main?.frame.height {
            // stderr and converted to screencapture's top-left origin, so a
            // capture can be aimed at the panel rather than guessed at.
            FileHandle.standardError.write(Data(
                ("[overlay show] rect=\(Int(frame.minX)),\(Int(screen - frame.maxY)),"
                 + "\(Int(frame.width)),\(Int(frame.height))\n").utf8))
        }
        return controller
    }

    /// One dictation after another, with the timings the real loop has: a
    /// transcription of about a second, a paste of 150 ms, the result held
    /// for 900 ms, then an error held for its 2.5 s.
    private static func runSequence(_ controller: OverlayController,
                                    at position: OverlayPosition) {
        func log(_ line: String) {
            FileHandle.standardError.write(Data("[overlay sequence] \(line)\n".utf8))
        }
        Task { @MainActor in
            while true {
                controller.model.transcriptIsOnClipboard = false
                controller.model.captureIsLive = true
                controller.update(state: .recording)
                controller.show(position: position)
                log("recording")
                // The meter breathing, as it would on speech.
                for tick in 0..<45 {
                    controller.model.level = Float(0.35 + 0.35 * sin(Double(tick) / 3))
                    controller.updateProgress(elapsed: Double(tick) / 30, limit: 600)
                    try? await Task.sleep(for: .milliseconds(33))
                }
                controller.update(state: .transcribing)
                log("transcribing")
                try? await Task.sleep(for: .milliseconds(1000))
                controller.update(state: .injecting)
                log("injecting")
                try? await Task.sleep(for: .milliseconds(150))
                controller.model.transcriptIsOnClipboard = true
                controller.update(state: .finished("Hello"))
                log("finished")
                try? await Task.sleep(for: .milliseconds(900))
                controller.update(state: .idle)
                controller.hide()
                log("hidden")
                try? await Task.sleep(for: .milliseconds(900))

                controller.update(state: .failed("Nothing returned"))
                controller.show(position: position)
                log("error")
                try? await Task.sleep(for: .milliseconds(1500))
                controller.update(state: .idle)
                controller.hide()
                log("hidden")
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    public static func write(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        var rows: [(String, OverlayModel)] = []

        func model(_ configure: (OverlayModel) -> Void) -> OverlayModel {
            let model = OverlayModel()
            model.isShown = true
            configure(model)
            return model
        }

        // captureIsLive matters: without it the meter renders dimmed and flat,
        // which is the waking pose rather than the recording one.
        rows.append(("recording", model {
            $0.state = .recording; $0.level = 0.75; $0.captureIsLive = true
        }))
        rows.append(("recording-quiet", model {
            $0.state = .recording; $0.level = 0.1; $0.captureIsLive = true
        }))
        rows.append(("recording-waking", model {
            $0.state = .recording; $0.level = 0.75   // captureIsLive stays false
        }))
        rows.append(("recording-near-limit", model {
            $0.state = .recording; $0.level = 0.6; $0.captureIsLive = true
            $0.progress = RecordingProgress(elapsed: 588, limit: 600)
        }))
        rows.append(("transcribing", model { $0.state = .transcribing }))
        rows.append(("transcribing-hover", model {
            $0.state = .transcribing; $0.isHovering = true
        }))
        rows.append(("error", model { $0.state = .failed("Nothing returned") }))
        rows.append(("error-long", model {
            $0.state = .failed("No model installed — open Settings ▸ Model to download one.")
        }))
        rows.append(("finished-copied", model {
            $0.state = .finished("Hello"); $0.transcriptIsOnClipboard = true
        }))
        rows.append(("finished-pasted", model { $0.state = .finished("Hello") }))
        rows.append(("preview", model { $0.isPreview = true }))
        rows.append(("nothing-heard", model {
            $0.state = .emptyResult("No speech detected.")
        }))
        // The two larger sizes, so the proportions can be checked against the
        // default rather than assumed to have scaled with it.
        rows.append(("recording-large", model {
            $0.state = .recording; $0.level = 0.75; $0.captureIsLive = true
            $0.size = .large
        }))
        rows.append(("transcribing-extra-large", model {
            $0.state = .transcribing; $0.size = .extraLarge
        }))

        for (name, model) in rows {
            let renderer = ImageRenderer(content:
                OverlayView(model: model)
                    // The dark card the design sits on, so the two can be
                    // compared side by side.
                    .background(Color(red: 54/255, green: 52/255, blue: 49/255)))
            renderer.scale = 3
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
        }
        print("[overlay dump] wrote \(rows.count) states to \(directory.path)")
    }
}
#endif
