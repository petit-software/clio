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

    public static func write(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        var rows: [(String, OverlayModel)] = []

        func model(_ configure: (OverlayModel) -> Void) -> OverlayModel {
            let model = OverlayModel()
            configure(model)
            return model
        }

        rows.append(("recording", model { $0.state = .recording; $0.level = 0.75 }))
        rows.append(("recording-quiet", model { $0.state = .recording; $0.level = 0.1 }))
        rows.append(("recording-near-limit", model {
            $0.state = .recording; $0.level = 0.6
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
        rows.append(("finished", model { $0.state = .finished("Hello") }))

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
