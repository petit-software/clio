import SwiftUI
import ClioCore

/// The meeting's recorder, at the foot of its page: the dictation pill
/// (`OverlayView`), brought into the window. The same surface, record dot
/// and level meter, then how long it has run and a stop; while the meeting
/// finishes, a word on what it is doing with the activity ring round the
/// rim, as a dictation has while it transcribes.
///
/// Always the light pill, whatever the appearance: it is the one live thing
/// on the page and should read as the recorder people already know.
struct MeetingPill: View {
    @Bindable var meeting: MeetingSession
    let stop: () -> Void

    /// Smaller than the floating pill's 52: here it shares a bar with
    /// 35-point controls.
    private let h: CGFloat = 44
    private let ink = Color.black
    private let surface = PillSurface()

    private var isWorking: Bool {
        meeting.phase == .finishing || meeting.phase == .summarizing
    }

    var body: some View {
        HStack(spacing: 0) {
            if meeting.isActive {
                recording
            } else {
                Text(label)
                    .font(.system(size: h * 0.3, weight: OverlayView.textWeight))
                    .foregroundStyle(meeting.phase.isFailure ? OverlayView.recordDot : ink)
                    .lineLimit(1)
                    .padding(.horizontal, h * 0.45)
                    .id(label)
                    .transition(.opacity)
            }
        }
        .frame(height: h)
        .background {
            PillBackground(tint: OverlayView.lightFill,
                           glassTint: Color.white.opacity(surface.style.glassTintLight),
                           outline: Color.black.opacity(surface.style.outlineLight),
                           surface: surface)
        }
        .overlay {
            if isWorking {
                ActivityRing(lineWidth: h * 0.045, ramp: ActivityRing.light)
                    .transition(.opacity)
            }
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        .environment(\.colorScheme, .light)
        .animation(.smooth(duration: 0.36), value: meeting.phase)
        .fixedSize()
    }

    private var recording: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(OverlayView.recordDot)
                .frame(width: h * 0.21, height: h * 0.21)
                .padding(.leading, h * 0.36)
                .padding(.trailing, h * 0.26)
            // Dimmed and still until the microphone is actually running.
            LevelMeter(level: meeting.phase == .recording ? meeting.micLevel : 0,
                       bands: meeting.phase == .recording ? meeting.micBands : [],
                       height: h, colour: ink)
                .opacity(meeting.phase == .recording ? 1 : 0.45)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(MeetingLine.timestamp(meeting.elapsed))
                    .font(.system(size: h * 0.3, weight: OverlayView.textWeight))
                    .monospacedDigit()
                    .foregroundStyle(ink)
            }
            .padding(.leading, h * 0.3)
            Button(action: stop) {
                Image(systemName: "stop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.monochrome)
                    // The floating pill's ✕ grey: a stop, quiet until wanted.
                    .foregroundStyle(Color(red: 158/255, green: 158/255, blue: 157/255))
                    .frame(width: h * 0.4, height: h * 0.4)
                    .padding(.leading, h * 0.26)
                    .padding(.trailing, h * 0.3)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop recording (⌘.)")
            .accessibilityLabel("Stop Recording")
        }
    }

    private var label: String {
        switch meeting.phase {
        case .starting, .recording: return ""
        case .finishing:
            return meeting.pendingChunks > 0
                ? "Finishing the transcript · \(meeting.pendingChunks) left"
                : "Finishing the transcript"
        case .summarizing: return "Writing the summary"
        case .finished: return "Saved · \(MeetingLine.timestamp(meeting.elapsed))"
        case .failed(let reason): return reason
        }
    }
}

private extension MeetingSession.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
