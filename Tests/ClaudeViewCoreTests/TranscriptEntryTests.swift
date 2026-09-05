import Foundation
import Testing

@testable import ClaudeViewCore

/// Fixture lines mirror shapes observed in real ~/.claude transcripts
/// (Claude Code v2.1.x), scrubbed of content.
enum Fixtures {
    static let userPrompt = """
        {"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"/Users/x/src/app","sessionId":"aaaa-1111","version":"2.1.221","gitBranch":"main","type":"user","message":{"role":"user","content":"Fix the bug in foo.swift"},"uuid":"u-1","timestamp":"2026-08-22T15:42:11.123Z"}
        """

    static let assistantText = """
        {"parentUuid":"u-1","isSidechain":false,"cwd":"/Users/x/src/app","sessionId":"aaaa-1111","version":"2.1.221","type":"assistant","requestId":"req_1","message":{"id":"msg_01AAA","type":"message","role":"assistant","model":"claude-fable-5","content":[{"type":"text","text":"Looking at **foo.swift** now."}],"usage":{"input_tokens":10,"output_tokens":42}},"uuid":"a-1","timestamp":"2026-08-22T15:42:20.001Z"}
        """

    static let assistantThinking = """
        {"parentUuid":"a-1","type":"assistant","sessionId":"aaaa-1111","message":{"id":"msg_01AAA","role":"assistant","content":[{"type":"thinking","thinking":"The bug is probably in the loop bounds.","signature":"sig=="}]},"uuid":"a-2","timestamp":"2026-08-22T15:42:21.500Z"}
        """

    static let assistantToolUse = """
        {"parentUuid":"a-2","type":"assistant","sessionId":"aaaa-1111","message":{"id":"msg_01AAA","role":"assistant","content":[{"type":"tool_use","id":"toolu_777","name":"Read","input":{"file_path":"/Users/x/src/app/foo.swift"}}]},"uuid":"a-3","timestamp":"2026-08-22T15:42:22Z"}
        """

    static let userToolResult = """
        {"parentUuid":"a-2","type":"user","sessionId":"aaaa-1111","message":{"role":"user","content":[{"tool_use_id":"toolu_777","type":"tool_result","content":[{"type":"text","text":"1\\tfunc foo() {}"}]}]},"toolUseResult":{"type":"text","file":{"filePath":"/Users/x/src/app/foo.swift","numLines":1}},"uuid":"u-2","timestamp":"2026-08-22T15:42:23Z"}
        """

    static let aiTitle = """
        {"type":"ai-title","aiTitle":"Fix foo.swift loop bounds","sessionId":"aaaa-1111"}
        """

    static let mysteryEntry = """
        {"type":"hologram-checkpoint","payload":{"future":"format"},"uuid":"h-1"}
        """

    static func entry(_ line: String, index: Int = 0) throws -> TranscriptEntry {
        try TranscriptEntry(line: Data(line.utf8), index: index)
    }
}

@Suite struct TranscriptEntryTests {
    @Test func userPromptWithPlainStringContent() throws {
        let e = try Fixtures.entry(Fixtures.userPrompt)
        #expect(e.kind == .user)
        #expect(e.uuid == "u-1")
        #expect(e.parentUuid == nil)
        #expect(!e.isMeta)
        #expect(e.timestamp != nil)
        guard case .text(let text)? = e.contentBlocks.first else {
            Issue.record("expected plain-string prompt to project as a text block")
            return
        }
        #expect(text == "Fix the bug in foo.swift")
    }

    @Test func assistantEntriesShareMessageId() throws {
        let text = try Fixtures.entry(Fixtures.assistantText)
        let thinking = try Fixtures.entry(Fixtures.assistantThinking, index: 1)
        let tool = try Fixtures.entry(Fixtures.assistantToolUse, index: 2)
        #expect(text.messageId == "msg_01AAA")
        #expect(text.messageId == thinking.messageId)
        #expect(text.messageId == tool.messageId)
        #expect(text.usage?["output_tokens"]?.intValue == 42)
    }

    @Test func contentBlockProjection() throws {
        let thinking = try Fixtures.entry(Fixtures.assistantThinking)
        guard case .thinking(let t)? = thinking.contentBlocks.first else {
            Issue.record("expected thinking block")
            return
        }
        #expect(t.contains("loop bounds"))

        let tool = try Fixtures.entry(Fixtures.assistantToolUse)
        guard case .toolUse(let id, let name, let input)? = tool.contentBlocks.first else {
            Issue.record("expected tool_use block")
            return
        }
        #expect(id == "toolu_777")
        #expect(name == "Read")
        #expect(input["file_path"]?.stringValue == "/Users/x/src/app/foo.swift")
    }

    @Test func toolResultPairsByToolUseId() throws {
        let e = try Fixtures.entry(Fixtures.userToolResult)
        #expect(e.kind == .user)
        guard case .toolResult(let toolUseId, let content, let isError)? = e.contentBlocks.first
        else {
            Issue.record("expected tool_result block")
            return
        }
        #expect(toolUseId == "toolu_777")
        #expect(!isError)
        #expect(ContentBlock.flattenedText(of: content).contains("func foo"))
        #expect(e.toolUseResult?["file"]?["filePath"]?.stringValue != nil)
    }

    @Test func sidecarEntries() throws {
        let e = try Fixtures.entry(Fixtures.aiTitle)
        #expect(e.kind == .aiTitle)
        #expect(e.aiTitle == "Fix foo.swift loop bounds")
        #expect(e.uuid == nil)
        #expect(e.id == "#0")
    }

    @Test func unknownKindsSurviveWithRawIntact() throws {
        let e = try Fixtures.entry(Fixtures.mysteryEntry)
        #expect(e.kind == .unknown("hologram-checkpoint"))
        // Bookkeeping or content is decided by the uuid, not by the type:
        // this one has one, so it is content the app has never met.
        #expect(e.uuid != nil)
        #expect(e.raw["payload"]?["future"]?.stringValue == "format")
        #expect(e.raw.prettyPrinted.contains("\"hologram-checkpoint\""))
    }

    @Test func timestampParsesWithAndWithoutFractionalSeconds() {
        #expect(TranscriptEntry.parseTimestamp("2026-08-22T15:42:20.001Z") != nil)
        #expect(TranscriptEntry.parseTimestamp("2026-08-22T15:42:22Z") != nil)
        #expect(TranscriptEntry.parseTimestamp("not a date") == nil)
    }
}

@Suite struct JSONValueTests {
    @Test func distinguishesBoolsFromNumbers() throws {
        let v = try JSONValue(data: Data(#"{"flag":true,"count":1}"#.utf8))
        #expect(v["flag"]?.boolValue == true)
        #expect(v["flag"]?.doubleValue == nil)
        #expect(v["count"]?.intValue == 1)
        #expect(v["count"]?.boolValue == nil)
    }

    @Test func prettyPrintIsStableAndEscaped() throws {
        let v = try JSONValue(data: Data(#"{"b":"line\nbreak","a":[1,2]}"#.utf8))
        #expect(v.prettyPrinted == """
            {
              "a": [
                1,
                2
              ],
              "b": "line\\nbreak"
            }
            """)
    }
}

@Suite struct JSONRenderTests {
    private func value(_ json: String) throws -> JSONValue {
        try JSONValue(data: Data(json.utf8))
    }

    @Test func bigIntegersSurviveExactly() throws {
        let v = try value(#"{"id":1700000000123456789}"#)
        #expect(v.prettyPrinted.contains("1700000000123456789"))
        guard case .integer(let i)? = v["id"] else {
            Issue.record("expected integer case")
            return
        }
        #expect(i == 1_700_000_000_123_456_789)
    }

    @Test func negativeZeroKeepsItsSign() throws {
        let v = try value(#"{"z":-0.0}"#)
        #expect(v.prettyPrinted.contains("-0.0"))
    }

    @Test func bidiAndLineSeparatorsEscape() throws {
        let v = JSONValue.object([
            "s": .string("a\u{202E}b\u{2028}c")
        ])
        let printed = v.prettyPrinted
        #expect(printed.contains("\\u202e"))
        #expect(printed.contains("\\u2028"))
        #expect(!printed.unicodeScalars.contains("\u{202E}"))
        #expect(!printed.unicodeScalars.contains("\u{2028}"))
    }

    @Test func displayOptionsTruncateContainersAndStrings() throws {
        let big = JSONValue.array((0..<10).map { .integer(Int64($0)) })
        var text = ""
        big.renderTokens(options: JSONRenderOptions(maxContainerItems: 3)) {
            text += $0.text
        }
        #expect(text.contains("… +7 more items"))
        // Full fidelity without options — prettyPrinted never truncates.
        #expect(!big.prettyPrinted.contains("more items"))

        let long = JSONValue.string(String(repeating: "x", count: 30))
        var clipped = ""
        long.renderTokens(options: JSONRenderOptions(stringLimit: 10)) {
            clipped += $0.text
        }
        #expect(clipped.contains("+20 bytes"))
    }

    @Test func alignedValuesShareAColumn() throws {
        let v = JSONValue.object(["a": .integer(1), "longer_key": .integer(2)])
        var text = ""
        v.renderTokens(options: JSONRenderOptions(alignValues: true)) {
            text += $0.text
        }
        let lines = text.split(separator: "\n").filter { $0.contains(":") }
        let valueColumns = lines.compactMap { line in
            line.lastIndex(of: " ").map { line.distance(from: line.startIndex, to: $0) }
        }
        #expect(Set(valueColumns).count == 1, "values should start at one column: \(text)")
    }

    /// Copy JSON has to produce JSON. Swift spells these "inf", "-inf" and
    /// "nan"; a parser handed any of them stops.
    @Test func infinitiesAreWrittenAsNull() {
        #expect(JSONValue.number(.infinity).prettyPrinted == "null")
        #expect(JSONValue.number(-.infinity).prettyPrinted == "null")
        #expect(JSONValue.number(.nan).prettyPrinted == "null")
        // Ordinary numbers are untouched.
        #expect(JSONValue.number(1.5).prettyPrinted == "1.5")
        #expect(JSONValue.number(3).prettyPrinted == "3")
        let object = JSONValue.object(["a": .number(-.infinity), "b": .integer(2)])
        #expect(
            (try? JSONSerialization.jsonObject(
                with: Data(object.prettyPrinted.utf8))) != nil)
    }
}
