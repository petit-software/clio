import ClioObjC
import Foundation

/// A Swift face on the one Objective-C function in the app.
///
/// `AVAudioEngine` raises `NSException` for what it considers misuse, and a
/// Bluetooth headset switching profile between one buffer and the next can
/// make a perfectly ordered tap install look like misuse. An NSException
/// crossing a Swift frame terminates the process — that was every crash
/// report this app has ever produced. Run those calls through here and the
/// exception comes back as a string to put in an error instead.
public enum ObjCException {
    /// Runs `body`; returns the reason of the exception it raised, or nil.
    public static func catching(_ body: () -> Void) -> String? {
        withoutActuallyEscaping(body) { escapable in
            CLIOCatchObjCException(escapable)
        }
    }
}
