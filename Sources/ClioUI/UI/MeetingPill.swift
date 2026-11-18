import SwiftUI
import ClioCore

/// The meeting's recorder, at the foot of its page: the dictation pill
/// (`OverlayView`), brought into the window. The same surface, record dot
/// and level meter, then how long it has run and a stop; while the meeting
/// finishes, a word on what it is doing with the activity ring round the
/// rim, as a dictation has while it transcribes.
///
/// The pill of the appearance the window is in, as a dictation's is: light
/// in light mode, black in the dark. It has been always light, then always
/// black; it follows the window now.
struct MeetingPill: View {
    @Bindable var meeting: MeetingSession
    let stop: () -> Void

    /// Two points over the bar's 35 and the Notes pull-down beside it —
    /// asked for — and well under the floating pill's 52. Its text is the
    /// pull-down's size, not a fraction of this, so the two read as one row.
    private let h: CGFloat = 37
    private let text = Font.system(size: 13, weight: OverlayView.textWeight)
    @Environment(\.colorScheme) private var scheme
    private var isDark: Bool { scheme == .dark }
    /// The pill's ink for the appearance, as `OverlayView` has it.
    private var ink: Color { isDark ? Color(white: 0.96) : .black }
    /// The floating pill's surface is half tint over clear glass, which
    /// hangs over a desktop. On a page that is the page's own colour: the
    /// tint is whole here, so the dark pill is black on a dark page and
    /// not charcoal, and the light one is its own off-white.
    private let surface = PillSurface(opacity: 1)

    private var isWorking: Bool {
        meeting.phase == .finishing || meeting.phase == .identifying
            || meeting.phase == .summarizing
    }

    var body: some View {
        HStack(spacing: 0) {
            if meeting.isActive {
                recording
            } else {
                Text(label)
                    .font(text)
                    .foregroundStyle(meeting.phase.isFailure ? OverlayView.recordDot : ink)
                    .lineLimit(1)
                    .padding(.horizontal, h * 0.45)
                    .id(label)
                    .transition(.opacity)
            }
        }
        .frame(height: h)
        .background {
            PillBackground(tint: isDark ? OverlayView.darkFill : OverlayView.lightFill,
                           glassTint: isDark ? Color.black.opacity(surface.style.glassTintDark)
                                             : Color.white.opacity(surface.style.glassTintLight),
                           outline: isDark ? Color.white.opacity(surface.style.outlineDark)
                                           : Color.black.opacity(surface.style.outlineLight),
                           surface: surface)
        }
        .overlay {
            if isWorking {
                ActivityRing(lineWidth: h * 0.045, ramp: isDark ? ActivityRing.dark : ActivityRing.light)
                    .transition(.opacity)
            }
        }
        // No shadow: the floating pill casts one to stand off whatever it
        // hangs over; here it sits in a bar beside controls that cast none.
        .clipShape(Capsule())
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
                    .font(text)
                    .monospacedDigit()
                    .foregroundStyle(ink)
            }
            .padding(.leading, h * 0.3)
            Button(action: stop) {
                Image(systemName: "stop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.monochrome)
                    // The floating pill's ✕ grey, for the appearance: a
                    // stop, quiet until wanted.
                    .foregroundStyle(isDark ? Color(white: 0.62)
                                            : Color(red: 158/255, green: 158/255, blue: 157/255))
                    .frame(width: h * 0.46, height: h * 0.46)
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
        case .identifying: return "Working out who spoke"
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
