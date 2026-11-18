import Foundation

/// One voice of one meeting: what the diarizer made of it, and how much it
/// had to go on.
public struct VoiceSample: Sendable, Equatable {
    public var vector: [Float]
    /// Seconds the voice spoke in the meeting. A voiceprint from fifteen
    /// words is worth less than one from ten minutes.
    public var seconds: TimeInterval

    public init(vector: [Float], seconds: TimeInterval) {
        self.vector = vector
        self.seconds = seconds
    }
}

/// A voice Clio has heard, kept: which meeting, which voice in it, the
/// voiceprint, and whose it was said to be.
public struct Voiceprint: Codable, Sendable, Equatable {
    /// The meeting, by its start — what the file's front matter carries and
    /// a rename does not change.
    public var meeting: String
    public var voice: Int
    public var date: Date
    /// 256 floats, as bytes: JSON writes `Data` in base64, a third the size
    /// of the numbers written out.
    public var vector: Data
    public var seconds: TimeInterval
    public var name: String?
    /// The address the calendar had for whoever the name is, when the
    /// meeting's invitation had one. What makes "Ana", "Ana R." and
    /// "Ana Ruiz" one person for certain, and tells two Anas apart.
    public var email: String?
    /// Whether the user gave the name, or accepted it.
    public var confirmed: Bool
    /// Which model made the vector. Two models' vectors mean different
    /// things and are never compared.
    public var space: String

    public init(meeting: String, voice: Int, date: Date, vector: [Float], seconds: TimeInterval,
                name: String?, email: String? = nil, confirmed: Bool, space: String) {
        self.email = email
        self.meeting = meeting
        self.voice = voice
        self.date = date
        self.vector = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        self.seconds = seconds
        self.name = name
        self.confirmed = confirmed
        self.space = space
    }

    public var floats: [Float] {
        vector.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

// MARK: - Matching

/// How sure a match is.
public enum VoiceMatchLevel: String, Sendable, Equatable {
    /// Close, heard often, confirmed by the user more than once, and nobody
    /// else near: taken as the name.
    case high
    /// Close enough to say so to a model that can weigh it against the
    /// conversation.
    case medium
    /// Within reach, not more.
    case low
    /// Two people it could be.
    case ambiguous
}

public struct VoiceMatch: Sendable, Equatable {
    public var level: VoiceMatchLevel
    /// The likeliest first. One name, or for `ambiguous` the two or three
    /// it lies between.
    public var names: [String]
    /// How far the nearest counted voiceprint of the first name is, 0…2.
    public var distance: Float
    /// Meetings the first name's match rests on, and how many of those the
    /// user confirmed.
    public var meetings: Int
    public var confirmedMeetings: Int

    public var name: String { names[0] }
}

/// Whose voice is this, going by the voices of earlier meetings.
///
/// The numbers are Biscotti's: calibrated on its author's own meetings
/// with the same embedder (Pyannote v3, W8A16) through the same SpeakerKit
/// release — same-person distances mostly under 0.32, the closest two
/// different people at 0.62. They are a starting point, not Clio's own
/// measurements; `VoiceMemory.report` prints the distances in a store so
/// they can be moved.
public struct VoiceprintMatcher: Sendable {
    /// Beyond this a voiceprint is no evidence at all.
    public var acceptRadius: Float = 0.50
    public var highDistance: Float = 0.20
    public var mediumDistance: Float = 0.30
    /// The most meetings counted for one person: the best of them.
    public var bestMeetings = 5
    /// What a name a model guessed is worth beside one the user gave. A
    /// guess can put one person's voice under another's name.
    public var guessWeight: Float = 0.2
    /// Speaking time from which a voiceprint counts in full.
    public var fullSeconds: TimeInterval = 60
    /// Being invited to this meeting makes a person likelier to be in it.
    public var invitedBoost: Float = 1.5
    /// The runner-up at this share of the leader's score makes it a tie.
    public var ambiguityRatio: Float = 0.6
    /// High needs the runner-up under this share.
    public var highMargin: Float = 0.35
    public var highMeetings = 3
    public var highConfirmed = 2
    /// Medium on guesses alone needs this many meetings.
    public var mediumGuessedMeetings = 3

    public init() {}

    struct Candidate {
        var name: String
        var score: Float
        var distance: Float
        var meetings: Int
        var confirmed: Int
    }

    /// The match for one voice, or nil when nothing heard before is near.
    /// `corpus` is other meetings' voiceprints; those of another model, or
    /// with no name, say nothing about who this is.
    ///
    /// `invitedEmails` are the addresses on this meeting's invitation: a
    /// person known by one of them is invited, whatever name the calendar
    /// shows for them this time.
    public func match(_ sample: VoiceSample, space: String, corpus: [Voiceprint],
                      invited: [String] = [], invitedEmails: [String] = []) -> VoiceMatch? {
        let invited = Set(invited.map(Self.key))
        let invitedEmails = Set(invitedEmails.map { $0.lowercased() })
        let named = corpus.filter { $0.space == space && !($0.name ?? "").isEmpty }
        var people = Self.people(named.compactMap(\.name))
        // An address settles who someone is: every name it has been seen
        // with is the person its fullest name is.
        var owner: [String: String] = [:]
        for print in named {
            guard let email = print.email?.lowercased(), !email.isEmpty,
                  let name = print.name, let person = people[Self.key(name)] else { continue }
            if let known = owner[email] {
                if person.count > known.count { owner[email] = person }
            } else {
                owner[email] = person
            }
        }
        var emails: [String: Set<String>] = [:]
        for print in named {
            guard let email = print.email?.lowercased(), let person = owner[email],
                  let name = print.name else { continue }
            people[Self.key(name)] = person
            emails[person, default: []].insert(email)
        }

        // What each named voiceprint within reach contributes, by person
        // and meeting — the best of a meeting if a person is in it twice.
        var contributions: [String: [String: (score: Float, distance: Float, confirmed: Bool)]] = [:]
        for print in named {
            let distance = VoiceprintMath.distance(sample.vector, print.floats)
            guard distance <= acceptRadius, let name = print.name,
                  let person = people[Self.key(name)] else { continue }
            let closeness = (acceptRadius - distance) / acceptRadius
            let speech = Float(min(1, print.seconds / fullSeconds))
            let score = closeness * (print.confirmed ? 1 : guessWeight) * speech
            let existing = contributions[person]?[print.meeting]
            if existing == nil || existing!.score < score {
                contributions[person, default: [:]][print.meeting] = (score, distance, print.confirmed)
            }
        }

        var candidates: [Candidate] = contributions.map { person, meetings in
            let best = meetings.values.sorted { $0.score > $1.score }.prefix(bestMeetings)
            var score = best.reduce(0) { $0 + $1.score }
            let key = Self.key(person)
            if invited.contains(key)
                || invited.contains(where: { Self.isShortFor($0, key) || Self.isShortFor(key, $0) })
                || !(emails[person] ?? []).isDisjoint(with: invitedEmails) {
                score *= invitedBoost
            }
            return Candidate(name: person, score: score,
                             distance: best.map(\.distance).min() ?? 2,
                             meetings: best.count,
                             confirmed: best.filter(\.confirmed).count)
        }
        candidates.sort { ($0.score, $1.name) > ($1.score, $0.name) }
        guard let first = candidates.first, first.score > 0 else { return nil }
        let second = candidates.dropFirst().first

        let level: VoiceMatchLevel
        var names = [first.name]
        if let second, second.score >= ambiguityRatio * first.score {
            level = .ambiguous
            names = candidates.prefix(3).filter { $0.score >= ambiguityRatio * first.score }.map(\.name)
        } else if first.distance <= highDistance, first.meetings >= highMeetings,
                  first.confirmed >= highConfirmed,
                  (second?.score ?? 0) <= highMargin * first.score {
            level = .high
        } else if first.distance <= mediumDistance,
                  first.confirmed >= 1 || first.meetings >= mediumGuessedMeetings {
            level = .medium
        } else {
            level = .low
        }
        return VoiceMatch(level: level, names: names, distance: first.distance,
                          meetings: first.meetings, confirmedMeetings: first.confirmed)
    }

    // MARK: Who is who

    static func key(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Whether `short` is a first name `full` begins with: "ana" for
    /// "ana ruiz". Both lowercased.
    static func isShortFor(_ short: String, _ full: String) -> Bool {
        !short.contains(" ") && full.hasPrefix(short + " ")
    }

    /// Each name as it is keyed, to the person it is taken for: itself, or
    /// — for a first name on its own — the one fuller name that begins with
    /// it. "Ana" typed in one meeting and "Ana Ruiz" in another are one
    /// person; with an "Ana Ruiz" and an "Ana Lee" both known, a bare "Ana"
    /// stays a person of its own rather than be given to either.
    static func people(_ names: [String]) -> [String: String] {
        var display: [String: String] = [:]
        for name in names where display[key(name)] == nil { display[key(name)] = name }
        var result: [String: String] = [:]
        for (key, name) in display {
            let fuller = display.keys.filter { isShortFor(key, $0) }
            result[key] = fuller.count == 1 ? display[fuller[0]]! : name
        }
        return result
    }
}

// MARK: - The store

/// The voices of past meetings, on disk, and what they say about a new one.
///
/// One JSON file in Application Support — not in the meetings folder, which
/// people sync and share. A voiceprint is a biometric: it is made on this
/// Mac, kept on this Mac, removed with its meeting, and removed altogether
/// from Settings.
public actor VoiceMemory {

    public let file: URL
    public var matcher = VoiceprintMatcher()
    private var prints: [Voiceprint]?

    public static var defaultFile: URL {
        AppPaths.supportDirectory.appendingPathComponent("voiceprints.json")
    }

    public init(file: URL = VoiceMemory.defaultFile) {
        self.file = file
    }

    /// How a meeting is known here: its start, as its file has it.
    public nonisolated static func key(for record: MeetingRecord) -> String {
        MeetingMarkdown.iso.string(from: record.startDate)
    }

    private func load() -> [Voiceprint] {
        if let prints { return prints }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: file))
            .flatMap { try? decoder.decode([Voiceprint].self, from: $0) } ?? []
        prints = loaded
        return loaded
    }

    private func store(_ new: [Voiceprint]) {
        prints = new
        if new.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(new) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    public var count: Int { load().count }

    /// How many different names the voices kept go by.
    public var peopleCount: Int {
        Set(VoiceprintMatcher.people(load().compactMap(\.name)).values).count
    }

    /// What earlier meetings say about each voice of this one.
    public func matches(for samples: [Int: VoiceSample], space: String, meeting: String,
                        invited: [String], invitedEmails: [String] = []) -> [Int: VoiceMatch] {
        let corpus = load().filter { $0.meeting != meeting }
        var result: [Int: VoiceMatch] = [:]
        for (voice, sample) in samples {
            result[voice] = matcher.match(sample, space: space, corpus: corpus,
                                          invited: invited, invitedEmails: invitedEmails)
        }
        return result
    }

    /// The address the meeting's invitation has for someone called `name`:
    /// theirs if the names are the same, or one is the other's first name.
    /// Nil when nobody invited is called that — or two are.
    nonisolated static func email(for name: String, in attendees: [MeetingAttendee]) -> String? {
        let key = VoiceprintMatcher.key(name)
        let found = attendees.filter { attendee in
            guard attendee.email != nil else { return false }
            let other = VoiceprintMatcher.key(attendee.name)
            return other == key || VoiceprintMatcher.isShortFor(key, other)
                || VoiceprintMatcher.isShortFor(other, key)
        }
        return found.count == 1 ? found[0].email : nil
    }

    /// Keeps a meeting's voices, with the names they have now, in place of
    /// whatever was kept for it before.
    public func remember(_ record: MeetingRecord, samples: [Int: VoiceSample], space: String) {
        let meeting = Self.key(for: record)
        var all = load().filter { $0.meeting != meeting }
        for (voice, sample) in samples.sorted(by: { $0.key < $1.key }) where !sample.vector.isEmpty {
            let named = record.voices[voice]
            all.append(Voiceprint(meeting: meeting, voice: voice, date: record.startDate,
                                  vector: sample.vector, seconds: sample.seconds,
                                  name: named?.name,
                                  email: named.flatMap { Self.email(for: $0.name, in: record.attendees) },
                                  confirmed: named?.confirmed ?? false,
                                  space: space))
        }
        store(all)
    }

    /// The names of a meeting's voices changed — the user named one, or
    /// took a name away. The voiceprints follow.
    public func rename(_ record: MeetingRecord) {
        let meeting = Self.key(for: record)
        var all = load()
        var changed = false
        for index in all.indices where all[index].meeting == meeting {
            let named = record.voices[all[index].voice]
            let email = named.flatMap { Self.email(for: $0.name, in: record.attendees) }
            if all[index].name != named?.name || all[index].confirmed != (named?.confirmed ?? false)
                || all[index].email != email {
                all[index].name = named?.name
                all[index].email = email
                all[index].confirmed = named?.confirmed ?? false
                changed = true
            }
        }
        if changed { store(all) }
    }

    /// A meeting was thrown away; its voices go with it.
    public func forget(meeting: String) {
        let all = load()
        let kept = all.filter { $0.meeting != meeting }
        if kept.count != all.count { store(kept) }
    }

    public func forgetAll() {
        store([])
    }

    /// The distances in the store, for moving the matcher's numbers on
    /// Clio's own data: between voiceprints the user confirmed as one
    /// person, and between ones confirmed as different people. The two
    /// lists should not overlap; where they stop is where the thresholds go.
    public func report() -> String {
        let confirmed = load().filter { $0.confirmed && !($0.name ?? "").isEmpty }
        let people = VoiceprintMatcher.people(confirmed.compactMap(\.name))
        var same: [Float] = [], different: [Float] = []
        for (index, a) in confirmed.enumerated() {
            for b in confirmed[(index + 1)...] where a.space == b.space && a.meeting != b.meeting {
                let distance = VoiceprintMath.distance(a.floats, b.floats)
                let one = people[VoiceprintMatcher.key(a.name!)] == people[VoiceprintMatcher.key(b.name!)]
                if one { same.append(distance) } else { different.append(distance) }
            }
        }
        func line(_ label: String, _ values: [Float]) -> String {
            guard !values.isEmpty else { return "[voiceprints] \(label): no pairs" }
            let sorted = values.sorted()
            func at(_ share: Double) -> Float { sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))] }
            return String(format: "[voiceprints] %@: %d pairs, min %.2f, median %.2f, p90 %.2f, max %.2f",
                          label, sorted.count, sorted[0], at(0.5), at(0.9), sorted[sorted.count - 1])
        }
        return """
            [voiceprints] \(load().count) kept, \(confirmed.count) with a name the user confirmed, \
            \(Set(people.values).count) people; accept \(matcher.acceptRadius), \
            high \(matcher.highDistance), medium \(matcher.mediumDistance)
            \(line("same person", same))
            \(line("different people", different))
            """
    }
}
