import SwiftUI
import ClioCore

/// Settings ▸ Day View: how the card with the day's events looks, when it
/// shows itself, and the calendar it reads. In builds that are not
/// releases, a Developer section too: made-up days and a made-up time.
struct DayViewTab: View {
    @Bindable var coordinator: AppCoordinator

    private var settings: ClioCore.Settings { coordinator.settingsStore.settings }

    /// A setting, and what has to follow it changing: an open panel taking
    /// the new look, or the next reminder being worked out again.
    private func setting<T>(_ keyPath: WritableKeyPath<ClioCore.Settings, T>,
                            then follow: @escaping @MainActor (AppCoordinator) -> Void
                                = { $0.refreshVisibleDay() }) -> Binding<T> {
        Binding(
            get: { coordinator.settingsStore.settings[keyPath: keyPath] },
            set: {
                coordinator.settingsStore.settings[keyPath: keyPath] = $0
                follow(coordinator)
            })
    }

    var body: some View {
        Form {
            Section {
                Picker("Stays on screen", selection: setting(\.dayViewSeconds)) {
                    ForEach(ClioCore.Settings.dayViewDurations, id: \.self) { seconds in
                        Text(ClioCore.Settings.dayViewLabel(forSeconds: seconds)).tag(seconds)
                    }
                }

                Picker("Layout", selection: setting(\.dayViewLayout)) {
                    ForEach(DayLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Countdown", selection: setting(\.dayViewCountdown)) {
                    ForEach(DayCountdownStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(settings.dayViewSeconds <= 0)

                LabeledContent("Position") {
                    DayPositionPicker(selection: setting(\.dayViewPosition))
                }

                HStack {
                    Spacer()
                    Button("Preview") { coordinator.showDay() }
                }
            } header: {
                Text("Day View")
            } footer: {
                Text("A card with today's events: all-day ones along the top, the rest by "
                     + "the hour, and a line where the day has got to. It counts down and "
                     + "goes — the count holds while the pointer is over it — and is in "
                     + "the menu bar menu as Show Day View.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Automatically") {
                Toggle("Show my day on startup and when my Mac wakes",
                       isOn: setting(\.dayViewOnWake) { _ in })
                Toggle("Show Day View before meetings",
                       isOn: setting(\.dayViewBeforeMeetings) { $0.scheduleDayReminder() })
                if settings.dayViewBeforeMeetings {
                    Picker("Show before start",
                           selection: setting(\.dayViewReminderMinutes) { $0.scheduleDayReminder() }) {
                        ForEach(ClioCore.Settings.dayViewReminderChoices, id: \.self) { minutes in
                            Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                        }
                    }
                }
                LaunchAtLoginToggle(coordinator: coordinator, title: "Open Clio at login")
            }

            Section {
                LabeledContent("Access") {
                    switch coordinator.calendar.access {
                    case .granted:
                        Label("Full access", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .notDetermined:
                        Button("Allow") { Task { await coordinator.calendar.requestAccess() } }
                    case .denied:
                        Label("Not granted", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                HStack {
                    Spacer()
                    Button("Open Privacy Settings…") { coordinator.calendar.openPrivacySettings() }
                }
            } header: {
                Text("Calendar")
            } footer: {
                Text("The day is read from your calendars on this Mac — the same access "
                     + "that names meeting notes. Events you declined are left out.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if AppCoordinator.isDeveloperBuild {
                DayViewDeveloperSection(coordinator: coordinator)
            }
        }
        .formStyle(.grouped)
    }
}

/// Made-up events instead of the calendar, and a time of day other than
/// now, so a long list, the empty state or the dimmed past can be watched
/// without arranging a day for them. Only in builds that are not releases.
private struct DayViewDeveloperSection: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Section {
            Toggle("Use sample events", isOn: $coordinator.dayDeveloper.useSampleEvents)
            Stepper("Timed events: \(coordinator.dayDeveloper.sampleTimedCount)",
                    value: $coordinator.dayDeveloper.sampleTimedCount, in: 0...40)
                .disabled(!coordinator.dayDeveloper.useSampleEvents)
            Stepper("All-day events: \(coordinator.dayDeveloper.sampleAllDayCount)",
                    value: $coordinator.dayDeveloper.sampleAllDayCount, in: 0...10)
                .disabled(!coordinator.dayDeveloper.useSampleEvents)
            Toggle("Set the time", isOn: $coordinator.dayDeveloper.overridesTime)
            DatePicker("Time", selection: $coordinator.dayDeveloper.overrideTime,
                       displayedComponents: .hourAndMinute)
                .disabled(!coordinator.dayDeveloper.overridesTime)
            HStack {
                Group {
                    Button("Empty Day") {
                        coordinator.dayDeveloper.sampleTimedCount = 0
                        coordinator.dayDeveloper.sampleAllDayCount = 0
                    }
                    Button("Busy Day") {
                        coordinator.dayDeveloper.sampleTimedCount = 24
                        coordinator.dayDeveloper.sampleAllDayCount = 6
                    }
                }
                .disabled(!coordinator.dayDeveloper.useSampleEvents)
                Spacer()
                Button("Preview") { coordinator.showDay() }
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Made-up events instead of your calendar, and a time of day other than "
                 + "now. Not saved: the day is your real one again after a relaunch. This "
                 + "section is in builds made with build-app.sh and not in releases.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        // An open panel follows along, so a long list or the empty state
        // can be watched while the numbers change.
        .onChange(of: coordinator.dayDeveloper) { coordinator.refreshVisibleDay() }
    }
}

/// A small picture of a screen with a spot for each place the panel can go.
private struct DayPositionPicker: View {
    @Binding var selection: DayPanelPosition

    private let screen = CGSize(width: 168, height: 104)
    private let spot = CGSize(width: 38, height: 24)
    private let inset: CGFloat = 8

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                // The menu bar.
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 6)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))

                ForEach(DayPanelPosition.allCases) { position in
                    let chosen = position == selection
                    Button { selection = position } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(chosen ? Color.accentColor : Color.primary.opacity(0.12))
                            .frame(width: spot.width, height: spot.height)
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(chosen ? 0 : 0.12), lineWidth: 0.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(position.title)
                    .accessibilityLabel(position.title)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .offset(offset(for: position))
                }
            }
            .frame(width: screen.width, height: screen.height)
            .animation(.easeOut(duration: 0.15), value: selection)

            Text(selection.title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func offset(for position: DayPanelPosition) -> CGSize {
        let top: CGFloat = 6 + inset
        let left = inset
        let right = screen.width - spot.width - inset
        let bottom = screen.height - spot.height - inset
        switch position {
        case .center: return CGSize(width: (screen.width - spot.width) / 2,
                                    height: (screen.height + 6 - spot.height) / 2)
        case .topLeft: return CGSize(width: left, height: top)
        case .topRight: return CGSize(width: right, height: top)
        case .bottomLeft: return CGSize(width: left, height: bottom)
        case .bottomRight: return CGSize(width: right, height: bottom)
        }
    }
}
