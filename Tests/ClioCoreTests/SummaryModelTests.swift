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
    func piecesForASmallModel() async {
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
        #expect(last.prompt.hasPrefix("Notes written during the meeting:\nwhat mattered"))
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
        await model.unload()
    }
}
