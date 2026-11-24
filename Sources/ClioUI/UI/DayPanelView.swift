import SwiftUI
import ClioCore

/// The card: the day, today's events, and the time left before it goes.
struct DayPanelView: View {
    @Bindable var model: DayPanelModel

    static let width: CGFloat = 340
    /// Transparent room around the card for its shadow. The window clips
    /// whatever falls outside it, and a blur fades out over about twice its
    /// radius, plus the offset: 22 × 2 + 10, rounded up.
    static let shadowMargin: CGFloat = 64
    static let cornerRadius: CGFloat = 22

    @State private var isHovering = false

    var body: some View {
        card
            .environment(\.isDayPanelHovered, isHovering)
            .frame(width: Self.width)
            .background(CardSurface(cornerRadius: Self.cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay {
                if model.countdownStyle == .border, !model.staysUntilClosed {
                    CountdownBorder(model: model, cornerRadius: Self.cornerRadius)
                }
            }
            .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
            .onHover { inside in
                isHovering = inside
                model.onHover(inside)
            }
            .scaleEffect(model.isShown ? 1 : DayPanelPlacement.hiddenScale, anchor: anchor)
            .offset(y: model.isShown ? 0 : entryOffset)
            .opacity(model.isShown ? 1 : 0)
            .padding(Self.shadowMargin)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)

            if model.events.isEmpty && model.layout == .list {
                EmptyDay()
            } else {
                let allDay = model.events.filter(\.isAllDay)
                let timed = model.events.filter { !$0.isAllDay }
                VStack(alignment: .leading, spacing: 14) {
                    if !allDay.isEmpty {
                        AllDayEvents(events: allDay)
                            .padding(.horizontal, 20)
                    }
                    // Ticks each minute, so a panel left open keeps the now
                    // line and the dimmed past current.
                    switch model.layout {
                    case .list where !timed.isEmpty:
                        TimelineView(.everyMinute) { context in
                            EventList(events: timed,
                                      now: context.date.addingTimeInterval(model.clockOffset))
                        }
                    case .timeline:
                        // Even with only all-day events: then the whole day
                        // is open, and that is worth seeing.
                        TimelineView(.everyMinute) { context in
                            DayTimeline(events: timed,
                                        now: context.date.addingTimeInterval(model.clockOffset))
                        }
                    default:
                        EmptyView()
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovering || model.staysUntilClosed {
                CloseButton { model.onClose() }
                    .padding(12)
                    .transition(.opacity)
            } else if model.countdownStyle == .ring {
                CountdownRing(model: model)
                    .frame(width: 20, height: 20)
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.day.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: 26, weight: .bold))
            Text(subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let date = model.day.formatted(.dateTime.day().month(.wide))
        switch model.events.count {
        case 0: return date
        case 1: return "\(date) · 1 event"
        case let n: return "\(date) · \(n) events"
        }
    }

    // MARK: Motion — `DayPanelPlacement`, which the meeting cards share

    private var anchor: UnitPoint { DayPanelPlacement.anchor(for: model.position) }
    private var entryOffset: CGFloat { DayPanelPlacement.entryOffset(for: model.position) }
}

// MARK: - Pieces

private struct EmptyDay: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sun.max")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text("Nothing planned for today.")
                .font(.system(size: 14, weight: .semibold))
            Text("Have a good one!")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

private struct EventList: View {
    let events: [DayEvent]
    let now: Date

    private static let maxHeight: CGFloat = 320

    var body: some View {
        ViewThatFits(in: .vertical) {
            rows.fixedSize(horizontal: false, vertical: true)

            DayScrollView(initialCenter: CGFloat(nowIndex ?? 0) * 42 + 8) {
                rows
            }
            .frame(height: Self.maxHeight)
        }
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Where the now line goes: before the first event still to start, so
    /// everything above it has begun.
    private var nowIndex: Int? {
        guard !events.isEmpty else { return nil }
        return events.firstIndex { $0.start > now } ?? events.count
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                if index == nowIndex {
                    NowLine(now: now)
                }
                EventRow(event: event, now: now)
                    .frame(minHeight: 38)
                    .id(event.id)
            }
            if nowIndex == events.count {
                NowLine(now: now)
            }
        }
        .padding(.horizontal, 20)
    }
}

/// All-day events as one group of chips, rather than a row each saying
/// "All day" — they have no time, so they need no place in the timeline.
private struct AllDayEvents: View {
    let events: [DayEvent]
    @State private var hoveredID: DayEvent.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("All day")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(events) { event in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(event.tint)
                            .frame(width: 6, height: 6)
                        DayEventTitle(event: event)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        DayEventLinkIndicator(event: event, isHovering: hoveredID == event.id)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(event.tint.opacity(0.16)))
                    .contentShape(Capsule())
                    .onHover { inside in
                        if inside {
                            hoveredID = event.id
                        } else if hoveredID == event.id {
                            hoveredID = nil
                        }
                    }
                    .help(event.title)
                }
            }
        }
    }
}

/// Left to right, wrapping onto a new line when the next one does not fit.
/// One too wide for a line of its own is given the whole line and truncates.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + lineHeight))
    }
}

/// The current time, as a line across the list the way Calendar draws it.
private struct NowLine: View {
    static let id = "now"
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            // Centred on the events' colour bars.
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .padding(.leading, -2)
            Rectangle()
                .fill(Color.red)
                .frame(height: 1.5)
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.red)
        }
        .padding(.vertical, 2)
        .id(Self.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now, \(now.formatted(date: .omitted, time: .shortened))")
    }
}

extension DayEvent {
    /// Its calendar's colour, or the accent where the calendar gave none.
    var tint: Color {
        color.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue) } ?? .accentColor
    }
}

struct DayEventTitle: View {
    let event: DayEvent

    var body: some View {
        if let url = event.url {
            Link(destination: url) {
                Text(event.title).foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help(url.absoluteString)
        } else {
            Text(event.title)
        }
    }
}

struct DayEventLinkIndicator: View {
    let event: DayEvent
    let isHovering: Bool

    var body: some View {
        if let url = event.url {
            Link(destination: url) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(event.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open link for " + event.title)
            .help(url.absoluteString)
            .fixedSize()
            .scaleEffect(isHovering ? 1 : 0.8)
            .opacity(isHovering ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
    }
}

private struct EventRow: View {
    let event: DayEvent
    let now: Date

    private var isNow: Bool { !event.isAllDay && event.start <= now && now < event.end }
    private var isPast: Bool { !event.isAllDay && event.end <= now }

    @State private var isHovering = false

    /// Grey once it is over — the colour says which calendar, which matters
    /// less for what is done — and back to the colour under the pointer.
    private var barColor: Color {
        isPast && !isHovering ? Color.gray.opacity(0.6) : event.tint
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Capsule()
                .fill(barColor)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                DayEventTitle(event: event)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                Group {
                    if let startsIn {
                        Text("in \(startsIn)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    } else if isNow {
                        Text("Now")
                            .font(.system(size: 10.5, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(Color.accentColor)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    }
                }
                .opacity(showsLink ? 0 : 1)
                DayEventLinkIndicator(event: event, isHovering: showsLink)
                    .allowsHitTesting(showsLink)
                    .accessibilityHidden(!showsLink)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
        .opacity(isPast ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private var showsLink: Bool { isHovering && event.url != nil }

    private var startsIn: String? {
        guard event.start > now else { return nil }
        let minutes = Int(ceil(event.start.timeIntervalSince(now) / 60))
        if minutes < 60 { return "\(minutes)m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }

    private var detail: String {
        [time, event.location].compactMap { $0 }.joined(separator: " · ")
    }

    private var time: String {
        if event.isAllDay { return "All day" }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        switch (event.start >= dayStart, event.end <= dayEnd) {
        case (true, true): return "\(start) – \(end)"
        case (true, false): return "From \(start)"
        case (false, true): return "Until \(end)"
        case (false, false): return "All day"
        }
    }
}

/// The same countdown as a line round the panel's edge, from twelve o'clock
/// clockwise, shrinking back to where it began.
private struct CountdownBorder: View {
    let model: DayPanelModel
    let cornerRadius: CGFloat

    private let lineWidth: CGFloat = 3
    private var outset: CGFloat { 4 + lineWidth / 2 }

    var body: some View {
        TimelineView(.animation(paused: model.deadline == nil)) { context in
            BorderOutline(cornerRadius: cornerRadius + outset)
                .trim(from: 0, to: model.fractionRemaining(at: context.date))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .padding(-outset)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A rounded rectangle traced from the middle of its top edge, clockwise —
/// SwiftUI's own starts in a corner, and a trim can only shorten a path
/// from its start.
private struct BorderOutline: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        // Screen coordinates: y grows downward, so "clockwise: false" in
        // Path's terms draws clockwise on screen.
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Time left before the panel goes, as a ring that empties at a constant
/// rate. Drawn from the countdown's deadline every frame, so a pause on
/// hover simply stops it.
private struct CountdownRing: View {
    let model: DayPanelModel

    private let size: CGFloat = 15
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        TimelineView(.animation(paused: model.deadline == nil)) { context in
            let fraction = model.fractionRemaining(at: context.date)
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    // From twelve o'clock.
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel("Close")
    }
}

/// Glass where the system has it, a material where it does not, under a
/// white tint in light mode and a black one in dark, so the text holds over
/// any backdrop.
private struct CardSurface: View {
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        (colorScheme == .dark ? Color.black : Color.white).opacity(0.75)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                shape
                    .fill(tint)
                    .glassEffect(.regular, in: shape)
            } else {
                shape
                    .fill(tint)
                    .background(.regularMaterial, in: shape)
            }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.24), lineWidth: 0.5))
    }
}

#if DEBUG
#Preview("Events") {
    let model = DayPanelModel()
    model.isShown = true
    model.total = 4.5
    model.deadline = Date().addingTimeInterval(3)
    model.events = SampleDay.events(timed: 6, allDay: 2, on: Date())
    return DayPanelView(model: model)
}

#Preview("Empty") {
    let model = DayPanelModel()
    model.isShown = true
    model.total = 0
    return DayPanelView(model: model)
}
#endif
