import AppKit
import SwiftUI
import ClioCore

/// The day as a timeline: hours down the side, each event a block as tall as
/// it is long. The free time is the space between them; it needs no label.
struct DayTimeline: View {
    /// Timed events only; all-day ones are drawn above, as chips.
    let events: [DayEvent]
    let now: Date

    private static let maxHeight: CGFloat = 352
    private static let labelRoom: CGFloat = 7

    var body: some View {
        let span = DaySpan(day: now)
        let hourHeight: CGFloat = 48
        let gridHeight = CGFloat(span.hours) * hourHeight

        DayScrollView(initialCenter: y(now, in: span, hourHeight: hourHeight) + Self.labelRoom) {
            GeometryReader { geometry in
                let gutter = Self.gutter(for: span)
                let lane = geometry.size.width - gutter
                let nowY = y(now, in: span, hourHeight: hourHeight)

                ZStack(alignment: .topLeading) {
                    hourGrid(span, width: geometry.size.width, gutter: gutter, hourHeight: hourHeight)

                    ForEach(DayEventColumns.place(events), id: \.event.id) { placed in
                        let top = y(max(placed.event.start, span.start), in: span, hourHeight: hourHeight)
                        let bottom = y(min(placed.event.end, span.end), in: span, hourHeight: hourHeight)
                        let columnWidth = (lane - 6) / CGFloat(placed.columns)
                        let height = max(bottom - top - 2, 14)
                        TimelineBlock(event: placed.event, now: now, height: height)
                            .frame(width: columnWidth - 2, height: height)
                            .offset(x: gutter + 6 + columnWidth * CGFloat(placed.column), y: min(top + 1, gridHeight - height))
                    }

                    if span.contains(now) {
                        nowLine(width: geometry.size.width, gutter: gutter)
                            .offset(y: nowY - 8)
                    }
                }
                .offset(y: Self.labelRoom)
            }
            .frame(height: gridHeight + 2 * Self.labelRoom)
            .padding(.horizontal, 20)
        }
        .frame(height: Self.maxHeight)
    }

    // MARK: Pieces

    private func y(_ date: Date, in span: DaySpan, hourHeight: CGFloat) -> CGFloat {
        CGFloat(span.hoursIn(date)) * hourHeight
    }

    /// The hour labels' column: as wide as the widest of them and no wider,
    /// so they line up with the header — "08" needs far less than "10 PM".
    private static func gutter(for span: DaySpan) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let widest = (0...span.hours)
            .map { NSAttributedString(string: span.hourLabel($0), attributes: [.font: font]).size().width }
            .max() ?? 0
        return ceil(widest) + 6
    }

    private func hourGrid(_ span: DaySpan, width: CGFloat, gutter: CGFloat, hourHeight: CGFloat) -> some View {
        ForEach(0...span.hours, id: \.self) { index in
            let y = CGFloat(index) * hourHeight
            HStack(spacing: 6) {
                Text(span.hourLabel(index))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: gutter - 6, alignment: .leading)
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)
            }
            .frame(width: width, height: 12)
            .offset(y: y - 6)
        }
    }

    /// The dot where the events begin, the line across them, and the time
    /// at its far end — on a pill, since it sits over whatever block is
    /// there.
    private func nowLine(width: CGFloat, gutter: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(Color.red)
                .frame(height: 1.5)
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.red))
        }
        .padding(.leading, gutter + 6 - 3.5)
        .frame(width: width, height: 16)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now, \(now.formatted(date: .omitted, time: .shortened))")
    }
}

// MARK: - Blocks

private struct TimelineBlock: View {
    let event: DayEvent
    let now: Date
    let height: CGFloat

    @State private var isHovering = false

    private var isPast: Bool { event.end <= now }
    private var isNow: Bool { event.start <= now && now < event.end }

    /// Grey once over, the calendar's colour under the pointer — as in the
    /// list.
    private var color: Color {
        isPast && !isHovering ? Color.gray : event.tint
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        HStack(alignment: .top, spacing: 5) {
            Capsule()
                .fill(color)
                .frame(width: 3)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 0) {
                DayEventTitle(event: event)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(height >= 44 ? 2 : 1)
                // A second line only where there is room for it.
                if height >= 28 {
                    Text(time)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, height >= 22 ? 3 : 0)
            Spacer(minLength: 0)
            DayEventLinkIndicator(event: event, isHovering: isHovering)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 3)
        .frame(maxHeight: .infinity, alignment: height >= 22 ? .top : .center)
        .background(shape.fill(color.opacity(isNow ? 0.26 : 0.16)))
        .clipShape(shape)
        .opacity(isPast ? 0.5 : 1)
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help("\(event.title)\n\(time)")
    }

    private var time: String {
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return [("\(start) – \(end)"), event.location].compactMap { $0 }.joined(separator: " · ")
    }
}
