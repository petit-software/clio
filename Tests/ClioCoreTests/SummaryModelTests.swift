import Testing
import Foundation
@testable import ClioCore

// MARK: - The summarizer, on a model that answers by rote

/// Answers every prompt the same way, and keeps what it was asked.
private final class ScriptedModel: SummaryLanguageModel, @unchecked Sendable {
    let pieceLimit: Int
    let answer: (String, String) -> String
    private(set) var prompts: [(instructions: String, prompt: String)] = []
    private let lock = NSLock()

    init(pieceLimit: Int, answer: @escaping (String, String) -> String = { _, _ in "### Topic\n- point" }) {
        self.pieceLimit = pieceLimit
        self.answer = answer
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        lock.withLock { prompts.append((instructions, prompt)) }
        return answer(instructions, prompt)
    }
}

@Suite("Summary models")
struct SummaryModelTests {

    private func record(lines: Int, text: String = "Something that was said in the meeting.") -> MeetingRecord {
        var record = MeetingRecord(title: "Sync")
        for index in 0..<lines {
            // Far enough apart not to be joined into one paragraph.
            record.add(MeetingLine(speaker: index.isMultiple(of: 2) ? .me : .others,
                                   start: Double(index) * 20, end: Double(index) * 20 + 5, text: text))
        }
        return record
    }

    @Test("A model that holds the whole transcript writes the summary from it in one request")
    func oneRequestWhenItFits() async {
        let model = ScriptedModel(pieceLimit: 100_000)
        let summary = await MeetingSummarizer.summarize(record(lines: 40), with: model)
        #expect(summary == "### Topic\n- point")
        #expect(model.prompts.count == 1)
        #expect(model.prompts[0].instructions == MeetingSummarizer.finalInstructions)
        #expect(model.prompts[0].prompt.contains("Transcript:\n[00:00] Me: Something"))
    }

    @Test("A small model gets the transcript in pieces, then the bullets, and the notes lead the last prompt")
    func piecesForASmallModel() async throws {
        let model = ScriptedModel(pieceLimit: 1_000) { instructions, _ in
            instructions == MeetingSummarizer.pieceInstructions ? "- a point" : "### Done"
        }
        var record = record(lines: 60)
        record.notes = "what mattered"
        let summary = await MeetingSummarizer.summarize(record, with: model)
        #expect(summary == "### Done")
        let pieces = model.prompts.filter { $0.instructions == MeetingSummarizer.pieceInstructions }
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.prompt.count <= 1_000 })
        let last = model.prompts.last!
        #expect(last.instructions == MeetingSummarizer.finalInstructions)
        // What the meeting was, then the notes, then the material.
        #expect(last.prompt.hasPrefix("Meeting: "))
        let notes = try #require(last.prompt.range(of: MeetingSummarizer.notesHeading + "\nwhat mattered"))
        let material = try #require(last.prompt.range(of: "Bullet points from the transcript:"))
        #expect(notes.lowerBound < material.lowerBound)
        #expect(last.prompt.contains("Bullet points from the transcript:\n- a point"))
    }

    @Test("A model that fails throughout leaves the meeting without a summary, not with an empty one")
    func failureIsNil() async {
        struct Broken: SummaryLanguageModel {
            var pieceLimit: Int { 1_000 }
            func respond(instructions: String, prompt: String) async throws -> String {
                throw SummaryError.generationFailed
            }
        }
        #expect(await MeetingSummarizer.summarize(record(lines: 5), with: Broken()) == nil)
        let silent = ScriptedModel(pieceLimit: 1_000) { _, _ in "   \n" }
        #expect(await MeetingSummarizer.summarize(record(lines: 5), with: silent) == nil)
    }

    @Test("A model's thinking and a fence around the answer are cut")
    func cleaning() {
        #expect(MeetingSummarizer.clean("<think>\nhmm\n</think>\n\n### Topic\n- point\n") == "### Topic\n- point")
        #expect(MeetingSummarizer.clean("```markdown\n### Topic\n- point\n```") == "### Topic\n- point")
        #expect(MeetingSummarizer.clean("<think>never closed") == "")
        #expect(MeetingSummarizer.clean("### Plain") == "### Plain")
    }

    @Test("The local model's piece follows its context")
    func localPieceLimit() {
        let small = LocalSummaryModel(file: URL(fileURLWithPath: "/nonexistent.gguf"), contextTokens: 4_096)
        let large = LocalSummaryModel(file: URL(fileURLWithPath: "/nonexistent.gguf"), contextTokens: 32_768)
        #expect(small.pieceLimit < large.pieceLimit)
        #expect(small.pieceLimit * 1 < 4_096 * 3)
        #expect(large.pieceLimit > MeetingSummarizer.pieceLimit)
    }

    @Test("The user's instructions replace Clio's for the summary, not for the pieces; empty ones are Clio's")
    func customInstructions() async {
        let model = ScriptedModel(pieceLimit: 1_000) { instructions, _ in
            instructions == MeetingSummarizer.pieceInstructions ? "- a point" : "Done"
        }
        _ = await MeetingSummarizer.summarize(record(lines: 40), with: model,
                                              instructions: "  Write three sentences.  ")
        #expect(model.prompts.last?.instructions == "Write three sentences.")
        #expect(model.prompts.dropLast().allSatisfy {
            $0.instructions == MeetingSummarizer.pieceInstructions
        })
        #expect(MeetingSummarizer.instructions(custom: " \n") == MeetingSummarizer.finalInstructions)
        #expect(MeetingSummarizer.instructions(custom: nil) == MeetingSummarizer.finalInstructions)
    }

    @Test("A title is the answer's first line with its marks off; an essay is no title")
    func titles() async {
        #expect(MeetingSummarizer.cleanTitle("**Pricing review.**\nBecause…") == "Pricing review")
        #expect(MeetingSummarizer.cleanTitle("Title: \"Q3 planning\"") == "Q3 planning")
        #expect(MeetingSummarizer.cleanTitle("## iOS beta") == "iOS beta")
        #expect(MeetingSummarizer.cleanTitle("  \n") == nil)
        #expect(MeetingSummarizer.cleanTitle(String(repeating: "word ", count: 30)) == nil)

        let model = ScriptedModel(pieceLimit: 5_000) { _, _ in "<think>hm</think>\n“Pricing review”" }
        let title = await MeetingSummarizer.title(forSummary: "### Pricing\n- Agreed.", with: model)
        #expect(title == "Pricing review")
        #expect(model.prompts.first?.instructions == MeetingSummarizer.titleInstructions)
        #expect(await MeetingSummarizer.title(forSummary: " ", with: model) == nil)
    }

    @Test("The context is made to fit the prompt, in steps, and never over the ceiling")
    func contextFitsThePrompt() {
        typealias Model = LocalSummaryModel
        // A short meeting on a big Mac gets a small context.
        #expect(Model.contextSize(forPrompt: 1_000, ceiling: 32_768) == 4_096)
        // 1,000 + 1,600 of answer + 256 of slack: one step is not enough.
        #expect(Model.contextSize(forPrompt: 300, ceiling: 32_768) == 4_096)
        #expect(Model.contextSize(forPrompt: 100, ceiling: 2_048) == 2_048)
        // A long one gets more room for its answer, up to a limit.
        #expect(Model.answerTokens(forPrompt: 0) == 1_500)
        #expect(Model.answerTokens(forPrompt: 10_000) == 2_500)
        #expect(Model.answerTokens(forPrompt: 100_000) == 4_000)
        #expect(Model.contextSize(forPrompt: 10_000, ceiling: 32_768) == 14_336)
        // The ceiling holds, and what does not fit under it is refused.
        #expect(Model.contextSize(forPrompt: 5_800, ceiling: 8_192) == 8_192)
        #expect(Model.contextSize(forPrompt: 6_000, ceiling: 8_192) == nil)
    }

    @Test("The ceiling follows the Mac's memory and the model's size; a piece cut at the limit fits under it")
    func ceilingFollowsMemory() {
        let gigabyte: UInt64 = 1 << 30
        func ceiling(_ ram: UInt64, weights: Double) -> Int {
            LocalSummaryModel.contextCeiling(ram: ram * gigabyte,
                                             weightsBytes: Int64(weights * Double(gigabyte)))
        }
        // A 4B model: the Mac is the limit.
        #expect(ceiling(8, weights: 2.5) == 8_192)
        #expect(ceiling(16, weights: 2.5) == 16_384)
        #expect(ceiling(32, weights: 2.5) == 32_768)
        // A 12B model: its own size is, until the Mac is large.
        #expect(ceiling(16, weights: 7.3) == 4_096)
        #expect((8_192...12_288).contains(ceiling(24, weights: 7.3)))
        #expect(ceiling(64, weights: 7.3) == 32_768)
        // Weights and cache together stay under half the memory.
        for (ram, weights) in [(24.0, 7.3), (32.0, 7.3), (16.0, 2.5), (8.0, 2.5)] {
            let bytes = Int64(weights * Double(gigabyte))
            let tokens = ceiling(UInt64(ram), weights: weights)
            let cache = Double(tokens) * LocalSummaryModel.cacheBytesPerToken(weightsBytes: bytes)
            #expect(Double(bytes) + cache <= ram * Double(gigabyte) / 2)
        }
        for ceiling in [8_192, 16_384, 32_768] {
            let model = LocalSummaryModel(file: URL(fileURLWithPath: "/nonexistent.gguf"),
                                          contextTokens: ceiling)
            // The piece at three characters a token, plus the instructions.
            let prompt = model.pieceLimit / 3 + 600
            #expect(LocalSummaryModel.contextSize(forPrompt: prompt, ceiling: ceiling) != nil)
        }
    }

    @Test("A missing file is a load error, not a crash")
    func missingFile() async {
        let model = LocalSummaryModel(file: URL(fileURLWithPath: "/nonexistent/model.gguf"))
        await #expect(throws: SummaryError.self) {
            try await model.respond(instructions: "x", prompt: "y")
        }
        #expect(await model.isLoaded == false)
    }
}

// MARK: - The real thing

/// A real GGUF through llama.cpp. Off by default — it needs a model on disk,
/// which is named rather than downloaded:
///
///     CLIO_INTEGRATION=1 CLIO_SUMMARY_MODEL=~/path/to/model.gguf swift test --filter SummaryModelIntegration
///
/// Any GGUF works, so a model can be proven before it is offered in the
/// catalog; the catalog's own are in Settings ▸ Model once downloaded,
/// under ~/Library/Application Support/com.bartbak.clio/models/<id>/.
private let summaryModelPath = ProcessInfo.processInfo.environment["CLIO_SUMMARY_MODEL"]
    .map { ($0 as NSString).expandingTildeInPath }
private let summaryIntegrationEnabled =
    ProcessInfo.processInfo.environment["CLIO_INTEGRATION"] != nil && summaryModelPath != nil

@Suite("SummaryModelIntegration", .enabled(if: summaryIntegrationEnabled), .serialized)
struct SummaryModelIntegrationTests {

    @Test("The model loads, answers a prompt in its chat format, and unloads")
    func answers() async throws {
        let model = LocalSummaryModel(file: URL(fileURLWithPath: summaryModelPath!), idleTime: .seconds(1))
        let began = Date()
        let answer = try await model.respond(
            instructions: "Answer in one short sentence.",
            prompt: "What colour is the sky on a clear day? /no_think")
        let elapsed = Date().timeIntervalSince(began)
        print("[summary-model] answered in \(String(format: "%.1f", elapsed)) s: \(answer)")
        let cleaned = MeetingSummarizer.clean(answer)
        #expect(cleaned.lowercased().contains("blue"))
        #expect(await model.isLoaded)
        try await Task.sleep(for: .seconds(2))
        #expect(await model.isLoaded == false)
    }

    @Test("A meeting transcript becomes Markdown notes with the catalog's headings")
    func summarizesAMeeting() async throws {
        var record = MeetingRecord(title: "Weekly product sync")
        record.notes = "- iOS beta date?\n- pricing page copy"
        let lines: [(MeetingSpeaker, TimeInterval, String)] = [
            (.others, 4, "Okay, I think everyone's here. Let's start with the beta."),
            (.me, 9, "The build is ready. I'd like to send it to testers on Thursday."),
            (.others, 16, "Thursday works. I'll write the release notes by Wednesday."),
            (.me, 24, "Next, the pricing page. The copy is drafted; design is reviewing the table."),
            (.others, 33, "Let's ship the page the week after the beta. Ana, can you do the final pass?"),
            (.others, 41, "Yes, I'll have it done by Friday."),
        ]
        for (speaker, start, text) in lines {
            record.add(MeetingLine(speaker: speaker, start: start, end: start + 4, text: text))
        }
        let model = LocalSummaryModel(file: URL(fileURLWithPath: summaryModelPath!), idleTime: .seconds(1))
        let began = Date()
        let summary = try #require(await MeetingSummarizer.summarize(record, with: model))
        print("[summary-model] summary in \(String(format: "%.1f", Date().timeIntervalSince(began))) s:\n\(summary)")
        #expect(summary.contains("### "))
        #expect(summary.lowercased().contains("thursday") || summary.lowercased().contains("beta"))
        #expect(!summary.contains("<think>"))
        print("[summary-model] context \(await model.currentContextTokens) of \(model.contextTokens) tokens")
        #expect(await model.currentContextTokens < model.contextTokens)

        // Who was invited is in the prompt now: the model can say who "Ana" is.
        record.attendees = [MeetingAttendee(name: "Ana Ruiz"), MeetingAttendee(name: "Tom Berg")]
        let named = try #require(await MeetingSummarizer.summarize(record, with: model))
        print("[summary-model] with attendees:\n\(named)")
        // Tom was invited and never named: nothing may be pinned on him.
        #expect(!named.contains("Tom"))

        // And a meeting with no title of its own gets one.
        let title = try #require(await MeetingSummarizer.title(forSummary: summary, with: model))
        print("[summary-model] title: \(title)")
        #expect(title.split(separator: " ").count <= 8)

        // The user's own instructions are followed in place of Clio's.
        let custom = try #require(await MeetingSummarizer.summarize(
            record, with: model,
            instructions: "Summarize the meeting in exactly one sentence. No headings, no lists."))
        print("[summary-model] custom instructions: \(custom)")
        #expect(!custom.contains("### "))

        // The notes steer it. One line of the call, in passing, is about
        // parking; nothing else is. With no note it is small talk; with a
        // note asking about it, it has to be in the summary — under Clio's
        // instructions and under the user's own, which never mention notes.
        var noted = MeetingRecord(title: "Weekly product sync")
        for (speaker, start, text) in lines {
            noted.add(MeetingLine(speaker: speaker, start: start, end: start + 4, text: text))
        }
        noted.add(MeetingLine(speaker: .others, start: 60, end: 64,
                              text: "By the way, the garage is closed on Monday, so park on the street."))
        noted.notes = "- where do we park monday?"
        let steered = try #require(await MeetingSummarizer.summarize(noted, with: model))
        print("[summary-model] with a note about parking:\n\(steered)")
        #expect(steered.lowercased().contains("park") || steered.lowercased().contains("garage"))
        let steeredCustom = try #require(await MeetingSummarizer.summarize(
            noted, with: model, instructions: "Summarize the meeting in two sentences."))
        print("[summary-model] the same, with the user's instructions: \(steeredCustom)")
        #expect(steeredCustom.lowercased().contains("park") || steeredCustom.lowercased().contains("garage"))
        noted.notes = ""
        let unsteered = try #require(await MeetingSummarizer.summarize(
            noted, with: model, instructions: "Summarize the meeting in two sentences."))
        print("[summary-model] and without the note: \(unsteered)")
        await model.unload()
    }
}
