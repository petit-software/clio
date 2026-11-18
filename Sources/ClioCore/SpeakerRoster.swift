import Foundation

/// Who can be on the other side of a call, by its invitation: everyone
/// invited who did not decline, less whoever is recording.
///
/// A language model reading a transcript for names takes any name it
/// meets. On a call of three — the one recording, Claire and Lukasz — it
/// heard "…, Bart?" and named Lukasz's voice Bart, who was "Me"; and a
/// few of Claire's words the diarizer had split off became "Thomas", a
/// child somebody mentioned. The invitation knew better on both counts,
/// and this is what holds a guess to it.
public struct SpeakerRoster: Sendable, Equatable {

    /// Whoever is recording, as the invitation has them. Nil when the
    /// calendar did not say which of those invited that is.
    public var me: String?
    /// Everyone else who was invited and did not decline.
    public var others: [String]

    public init(me: String? = nil, others: [String] = []) {
        self.me = me
        self.others = others
    }

    public init(attendees: [MeetingAttendee]) {
        var others: [String] = []
        for attendee in attendees where !attendee.declined {
            guard let name = attendee.personName else { continue }
            if attendee.isMe {
                me = name
            } else if !others.contains(where: { Self.tokens($0) == Self.tokens(name) }) {
                others.append(name)
            }
        }
        self.others = others
    }

    /// Who a name belongs to.
    enum Person: Equatable {
        /// The one recording: never a voice on the other side.
        case me
        /// One of the others, by its place in `others`.
        case other(Int)
        /// Nobody invited.
        case nobody
        /// More than one of those invited, and no telling which.
        case unclear
    }

    /// "Claire" is Claire Rumore, and so is "Claire Rumore-Smith" for an
    /// invitation that says only "Claire": one name's words are all among
    /// the other's. A name that is exactly someone's wins over one that is
    /// only part of someone else's.
    func person(named name: String) -> Person {
        let asked = Self.tokens(name)
        guard !asked.isEmpty else { return .nobody }
        var everyone: [(Person, Set<String>)] = others.enumerated().map { (.other($0.offset), Self.tokens($0.element)) }
        if let me { everyone.append((.me, Self.tokens(me))) }

        let exact = everyone.filter { $0.1 == asked }
        if exact.count == 1 { return exact[0].0 }
        let like = everyone.filter { !$0.1.isEmpty && ($0.1.isSubset(of: asked) || asked.isSubset(of: $0.1)) }
        switch like.count {
        case 0: return .nobody
        case 1: return like[0].0
        default: return .unclear
        }
    }

    /// The guesses that can be true, and one more when only one is left.
    ///
    /// `guesses` are a model's, by voice; `known` are the names that stand
    /// already — the user's, and those the voices themselves are sure of;
    /// `voices` is every voice heard. What comes back are guesses only.
    ///
    /// - The name of whoever is recording is no voice's.
    /// - A name that could be either of two people invited is nobody's.
    /// - A person is one voice: given to two, the guess is wrong about at
    ///   least one, and both are left out; given a name that stands
    ///   already, it is left out.
    /// - With no more voices than people invited, a name nobody invited
    ///   has is one that was only talked about. With more voices than
    ///   that, someone is on the call who was not invited, and a name from
    ///   outside the list is allowed.
    /// - With exactly as many voices as people invited, and whoever is
    ///   recording known: one voice left without a name and one person
    ///   left without a voice are each other's.
    public func settle(_ guesses: [Int: String], known: [Int: String] = [:], voices: [Int]) -> [Int: String] {
        let closed = !others.isEmpty && voices.count <= others.count
        var taken = Set<Int>()
        for name in known.values {
            if case .other(let index) = person(named: name) { taken.insert(index) }
        }
        let standing = Set(known.values.map { Self.tokens($0) })

        var invited: [Int: [Int]] = [:]      // a place in `others` → the voices guessed to be them
        var outside: [Int: String] = [:]
        for (voice, name) in guesses where known[voice] == nil && voices.contains(voice) {
            switch person(named: name) {
            case .me, .unclear:
                continue
            case .other(let index):
                if !taken.contains(index) { invited[index, default: []].append(voice) }
            case .nobody:
                if !closed, !standing.contains(Self.tokens(name)) { outside[voice] = name }
            }
        }

        var result = outside
        for (index, heard) in invited where heard.count == 1 {
            result[heard[0]] = others[index]
            taken.insert(index)
        }

        if closed, me != nil, voices.count == others.count {
            let unnamed = voices.filter { known[$0] == nil && result[$0] == nil }
            let free = others.indices.filter { !taken.contains($0) }
            // Everyone else accounted for: a name that stands for somebody
            // not invited leaves two people free, and nothing follows.
            if unnamed.count == 1, free.count == 1 { result[unnamed[0]] = others[free[0]] }
        }
        return result
    }

    /// A name as the words it is made of, for comparing: lowercased,
    /// without accents — "Łukasz" in an invitation is "Lukasz" in a
    /// transcript — and without whatever is not a letter or a digit.
    static func tokens(_ name: String) -> Set<String> {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "đ", with: "d")
        return Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }
}

extension MeetingAttendee {
    /// What to call them: the name the invitation has, or — when it has
    /// only an address, or gives the address as the name — the address's
    /// own words: "claire.rumore@example.com" is Claire Rumore. Nil for an
    /// address with no words in it.
    public var personName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !trimmed.contains("@") {
            // The calendar's fallback for no name at all is the address up
            // to its @: "claire.rumore", which is words in need of the same
            // reading.
            guard let email, trimmed == email.components(separatedBy: "@").first else { return trimmed }
        }
        let address = trimmed.contains("@") ? trimmed : (email ?? trimmed)
        let local = (address.components(separatedBy: "@").first ?? "")
            .components(separatedBy: "+").first ?? ""
        let words = local.split(whereSeparator: { !$0.isLetter })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
