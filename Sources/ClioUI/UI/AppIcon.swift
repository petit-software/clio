import AppKit
import SwiftUI

/// The app icon as artwork, for views that show it large inside a window:
/// the intro card and the About pane.
///
/// Three places it can come from, tried in order. `IntroIcon.png` is the
/// full-colour export the build scripts copy into Contents/Resources, and is
/// the right thing on screen: the `.icns` is inset for Finder's grid and looks
/// small beside text. A preview has no bundle, so DEBUG builds read the same
/// artwork out of the checkout instead. Last, whatever the running process is
/// using — a bare `swift run` binary gets the generic app icon, which at least
/// is the right shape.
enum AppIcon {
    static var image: Image { Image(nsImage: nsImage) }

    static var nsImage: NSImage {
        if let url = Bundle.main.url(forResource: "IntroIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        #if DEBUG
        if let image = NSImage(contentsOf: checkoutArtwork) {
            return image
        }
        #endif
        return NSApp?.applicationIconImage ?? NSImage()
    }

    #if DEBUG
    /// Sources/ClioUI/UI/AppIcon.swift → Resources/Icon/default.png.
    private static var checkoutArtwork: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UI
            .deletingLastPathComponent()   // ClioUI
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Resources/Icon/default.png")
    }
    #endif
}
