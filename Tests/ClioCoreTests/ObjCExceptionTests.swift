import Testing
import Foundation
@testable import ClioCore

/// The one thing that stands between an AVAudioEngine complaint and a dead
/// process. If this stops catching, the recorder is back to crashing.
@Suite("Objective-C exceptions")
struct ObjCExceptionTests {

    @Test("A raised NSException comes back as its reason")
    func exceptionIsCaught() {
        let reason = ObjCException.catching {
            NSException(name: .internalInconsistencyException,
                        reason: "required condition is false: nullptr == Tap()",
                        userInfo: nil).raise()
        }
        #expect(reason == "required condition is false: nullptr == Tap()")
    }

    @Test("A block that does not raise returns nil, and its work is done")
    func normalBlockRunsThrough() {
        var ran = false
        let reason = ObjCException.catching { ran = true }
        #expect(reason == nil)
        #expect(ran)
    }
}
