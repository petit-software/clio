import Testing
import Foundation
@testable import ClioCore

/// What the meter is fed. The complaint that prompted this was "the bars
/// barely move", so the thing to pin down is how far a voice swings them.
@Suite("Level scaler")
struct LevelScalerTests {

    private func rms(_ db: Float) -> Float { pow(10, db / 20) }

    @Test("Speech uses most of the meter, silence none of it")
    func speechSwingsTheMeter() {
        var scaler = LevelScaler()
        // A quiet room, and the gap between words.
        #expect(scaler.level(rms: rms(-60), dt: 1 / 30) == 0)
        #expect(scaler.level(rms: rms(-50), dt: 1 / 30) == 0)
        // A conversational word into a laptop microphone.
        let word = scaler.level(rms: rms(-22), dt: 1 / 30)
        #expect(word > 0.75 && word < 0.85)
        // A soft one still clears the middle.
        let soft = scaler.level(rms: rms(-32), dt: 1 / 30)
        #expect(soft > 0.5)
    }

    @Test("A loud word raises the ceiling, and it sinks back afterwards")
    func ceilingTracksAndDecays() {
        var scaler = LevelScaler()
        #expect(scaler.level(rms: rms(-5), dt: 1 / 30) == 1)
        #expect(scaler.ceilingDB == -5)
        // The next normal word is smaller against that ceiling...
        let after = scaler.level(rms: rms(-22), dt: 1 / 30)
        #expect(after < 0.7)
        // ...but a second of quiet brings the ceiling most of the way down.
        for _ in 0..<30 { _ = scaler.level(rms: rms(-60), dt: 1 / 30) }
        #expect(scaler.ceilingDB < -13)
        #expect(scaler.ceilingDB >= LevelScaler.minimumCeilingDB)
    }

    @Test("Silence never fills the meter, however long it lasts")
    func silenceDoesNotFillTheMeter() {
        var scaler = LevelScaler()
        var top: Float = 0
        for _ in 0..<300 { top = max(top, scaler.level(rms: rms(-45), dt: 1 / 30)) }
        #expect(top < 0.2)
        #expect(scaler.ceilingDB == LevelScaler.minimumCeilingDB)
    }

    @Test("Zero and absurd input are clamped, not NaN")
    func clamps() {
        var scaler = LevelScaler()
        #expect(scaler.level(rms: 0, dt: 1 / 30) == 0)
        #expect(scaler.level(rms: 100, dt: 1 / 30) == 1)
    }
}
