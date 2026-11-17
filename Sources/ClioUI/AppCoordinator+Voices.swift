import Foundation
import ClioCore

/// Whose the voices on a call are: what earlier meetings' voices say, then
/// what the conversation says, and keeping this meeting's for the next.
extension AppCoordinator {

    /// The names for a meeting's voices, as guesses.
    ///
    /// A voice that earlier meetings are sure of — close, heard often,
    /// confirmed by the user more than once — is named from them alone, and
    /// stands in the transcript under that name for the model to read. The
    /// rest are the model's to work out, with whatever weaker likeness
    /// there is given to it as evidence. Without a model, only the first
    /// kind are named.
    func nameVoices(of record: MeetingRecord, _ voices: IdentifiedVoices,
                    with model: (any SummaryLanguageModel)?,
                    ending session: MeetingSession?) async -> [Int: String] {
        var names: [Int: String] = [:]
        var hints: [Int: VoiceMatch] = [:]
        if settingsStore.settings.rememberVoices {
            let invited = record.attendees.filter { !$0.declined }.map(\.name)
            let matches = await voiceMemory.matches(
                for: voices.samples, space: voices.space,
                meeting: VoiceMemory.key(for: record), invited: invited)
            for (voice, match) in matches {
                if match.level == .high { names[voice] = match.name } else { hints[voice] = match }
            }
        }
        guard let model else { return names }

        var known = record
        for (voice, name) in names { known.name(voice: voice, as: name, confirmed: true) }
        await makeRoomForSummary(by: model, ending: session)
        for (voice, name) in await SpeakerNamer.names(for: known, with: model, matches: hints)
        where names[voice] == nil {
            names[voice] = name
        }
        return names
    }

    /// A voice was named, or its name taken away, by hand — in a live
    /// meeting or a saved one. The voiceprints kept for the meeting follow.
    public func voicesRenamed(in record: MeetingRecord) {
        Task {
            await voiceMemory.rename(record)
            refreshVoiceCount()
        }
    }

    /// A meeting is being thrown away: its voices are not kept without it.
    public func forgetVoices(ofMeetingAt url: URL) {
        guard let record = library?.record(at: url) else { return }
        let key = VoiceMemory.key(for: record)
        Task {
            await voiceMemory.forget(meeting: key)
            refreshVoiceCount()
        }
    }

    /// Settings ▸ Model ▸ Speakers: everything kept, gone.
    public func forgetAllVoices() {
        Task {
            await voiceMemory.forgetAll()
            refreshVoiceCount()
        }
    }

    /// For Settings: how many voices are kept, of how many people.
    public func refreshVoiceCount() {
        Task {
            let count = await voiceMemory.count
            let people = await voiceMemory.peopleCount
            rememberedVoices = (count, people)
        }
    }
}
