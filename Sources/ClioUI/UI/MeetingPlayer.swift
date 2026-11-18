import AVFoundation
import ClioCore
import SwiftUI

/// Plays a meeting's kept audio: both sides at once, each from its own
/// file, started together so they stay on the one clock they were recorded
/// on. Second 754 of the playback is the line stamped 12:34.
@MainActor
@Observable
final class MeetingPlayer {
    private var players: [AVAudioPlayer] = []
    private var ticker: Timer?

    private(set) var isPlaying = false
    /// Where playback is, in seconds from the start of the meeting.
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var hasAudio: Bool { !players.isEmpty }

    /// Opens whatever audio the meeting has. False when it has none.
    @discardableResult
    func load(meeting: URL) -> Bool {
        stop()
        players = MeetingAudio.files(for: meeting).values.compactMap {
            try? AVAudioPlayer(contentsOf: $0)
        }
        players.forEach { $0.prepareToPlay() }
        duration = players.map(\.duration).max() ?? 0
        time = 0
        return hasAudio
    }

    func play(from seconds: TimeInterval? = nil) {
        guard hasAudio else { return }
        let start = min(max(0, seconds ?? time), max(0, duration - 0.1))
        players.forEach { $0.stop() }
        // One moment on the device's clock for both, a little ahead, so
        // neither starts before the other is ready.
        let when = (players.first?.deviceCurrentTime ?? 0) + 0.08
        for player in players where start < player.duration {
            player.currentTime = start
            player.play(atTime: when)
        }
        time = start
        isPlaying = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        players.forEach { $0.pause() }
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        pause()
        players.forEach { $0.stop() }
        time = 0
    }

    private func tick() {
        let playing = players.filter(\.isPlaying)
        guard let current = playing.map(\.currentTime).max() else {
            // Both ran out: back to the start, ready to play again.
            isPlaying = false
            ticker?.invalidate()
            ticker = nil
            time = 0
            return
        }
        time = current
    }
}

/// Play and where it has got to, in the middle of a saved meeting's bar —
/// where the recorder was while it was being recorded.
struct PlayerControl: View {
    let player: MeetingPlayer

    var body: some View {
        Button {
            player.toggle()
        } label: {
            Text((player.isPlaying ? "Pause" : "Play")
                 + " · \(MeetingLine.timestamp(player.time)) / \(MeetingLine.timestamp(player.duration))")
                .monospacedDigit()
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .frame(height: 35)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(BarFill.colour, in: Capsule())
        .help(player.isPlaying ? "Pause" : "Play the meeting's audio. Click a time in the transcript to play from there.")
    }
}
