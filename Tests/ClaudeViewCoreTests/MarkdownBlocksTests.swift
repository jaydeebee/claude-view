import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct MarkdownBlocksTests {
    private func plain(_ block: MarkdownBlock) -> String {
        String(block.content.characters)
    }

    @Test func fencedCodeKeepsItsNewlines() {
        // The founding regression: a commit listing inside a fence was
        // hoisted onto one line by inline-only parsing.
        let text = """
            Here is the story:

            ```
            4eca946 Charter
            8118ac1 Scaffold
            ```
            """
        let blocks = MarkdownBlocks.parse(text)
        #expect(blocks.count == 2)
        guard case .code(let language) = blocks[1].kind else {
            Issue.record("expected a code block, got \(blocks[1].kind)")
            return
        }
        #expect(language == nil)
        #expect(plain(blocks[1]) == "4eca946 Charter\n8118ac1 Scaffold")
    }

    @Test func softLineBreaksSurviveAsLineBreaks() {
        // Same failure as the fence one, one level down: hard-wrapped
        // prose was hoisted onto a single line by CommonMark's
        // soft-break-to-space rule.
        let blocks = MarkdownBlocks.parse("line one\nline two\nline three")
        #expect(blocks.count == 1)
        #expect(plain(blocks[0]) == "line one\nline two\nline three")

        let item = MarkdownBlocks.parse("- one\n  two")
        #expect(plain(item[0]) == "one\ntwo")

        let quote = MarkdownBlocks.parse("> one\n> two")
        #expect(plain(quote[0]) == "one\ntwo")

        // A blank line is still a paragraph break, not a run of newlines.
        let paras = MarkdownBlocks.parse("first\n\nsecond")
        #expect(paras.count == 2)
        #expect(plain(paras[0]) == "first")
        #expect(plain(paras[1]) == "second")
    }

    @Test func languageHintSurvives() {
        let blocks = MarkdownBlocks.parse("```swift\nlet x = 1\n```")
        guard case .code(let language) = blocks.first?.kind else {
            Issue.record("expected a code block")
            return
        }
        #expect(language == "swift")
        #expect(plain(blocks[0]) == "let x = 1")
    }

    @Test func mixedDocumentKeepsOrder() {
        let text = """
            # Title

            A paragraph with **bold**.

            - first
            - second

            ---
            """
        let blocks = MarkdownBlocks.parse(text)
        #expect(blocks.count == 5)
        guard case .heading(let level) = blocks[0].kind else {
            Issue.record("expected heading first")
            return
        }
        #expect(level == 1)
        guard case .paragraph = blocks[1].kind else {
            Issue.record("expected paragraph second")
            return
        }
        guard case .listItem(let marker1, let indent1) = blocks[2].kind,
            case .listItem(let marker2, _) = blocks[3].kind
        else {
            Issue.record("expected two list items")
            return
        }
        #expect(marker1 == "•")
        #expect(marker2 == "•")
        #expect(indent1 == 1)
        #expect(plain(blocks[2]) == "first")
        guard case .divider = blocks[4].kind else {
            Issue.record("expected divider last")
            return
        }
    }

    @Test func orderedListsCountForThemselves() {
        let blocks = MarkdownBlocks.parse("1. alpha\n2. beta\n3. gamma")
        let markers = blocks.compactMap { block -> String? in
            if case .listItem(let marker, _) = block.kind { return marker }
            return nil
        }
        #expect(markers == ["1.", "2.", "3."])
    }

    @Test func nestedListsIndent() {
        let blocks = MarkdownBlocks.parse("- outer\n  - inner")
        let indents = blocks.compactMap { block -> Int? in
            if case .listItem(_, let indent) = block.kind { return indent }
            return nil
        }
        #expect(indents == [1, 2])
    }

    @Test func tablesComeThroughStructured() {
        let text = """
            | Name | Role |
            |------|------|
            | Tailer | reads |
            | Assembler | folds |
            """
        let blocks = MarkdownBlocks.parse(text)
        #expect(blocks.count == 1)
        guard case .table(let table) = blocks[0].kind else {
            Issue.record("expected a table, got \(blocks[0].kind)")
            return
        }
        #expect(table.header.map { String($0.characters) } == ["Name", "Role"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0].map { String($0.characters) } == ["Tailer", "reads"])
        #expect(table.rows[1].map { String($0.characters) } == ["Assembler", "folds"])
    }

    @Test func blockquotesAndPlainText() {
        let blocks = MarkdownBlocks.parse("> wisdom here")
        guard case .blockquote = blocks.first?.kind else {
            Issue.record("expected blockquote")
            return
        }
        #expect(plain(blocks[0]) == "wisdom here")

        let plainBlocks = MarkdownBlocks.parse("just some text, no markdown at all")
        #expect(plainBlocks.count == 1)
        guard case .paragraph = plainBlocks[0].kind else {
            Issue.record("expected paragraph")
            return
        }
    }

    @Test func emptyInputYieldsNothing() {
        #expect(MarkdownBlocks.parse("").isEmpty)
    }

    /// A quote containing anything but a bare paragraph lost its quoting:
    /// the list and code branches answered first and returned.
    @Test func quotedListsAndFencesStayQuoted() {
        let blocks = MarkdownBlocks.parse(
            """
            > quoted paragraph
            >
            > - quoted item
            > - another
            >
            > ```
            > quoted code
            > ```

            unquoted paragraph
            """)
        let quoted = blocks.filter(\.isQuoted)
        #expect(quoted.count >= 4, "expected the paragraph, both items and the fence")
        #expect(quoted.contains { if case .listItem = $0.kind { return true } else { return false } })
        #expect(quoted.contains { if case .code = $0.kind { return true } else { return false } })
        // The trailing paragraph is outside the quote.
        #expect(blocks.last?.isQuoted == false)
    }

    /// Tables never pass through a block flush, so the quoting field the
    /// flush maintained was already cleared by the time one was emitted.
    @Test func aQuotedTableKeepsItsBar() {
        let blocks = MarkdownBlocks.parse(
            """
            > | a | b |
            > | - | - |
            > | 1 | 2 |
            """)
        guard let table = blocks.first(where: {
            if case .table = $0.kind { return true } else { return false }
        }) else {
            Issue.record("expected a table")
            return
        }
        #expect(table.isQuoted)

        // And an unquoted one is still unquoted.
        let plain = MarkdownBlocks.parse("| a | b |\n| - | - |\n| 1 | 2 |")
        #expect(plain.contains { if case .table = $0.kind { return !$0.isQuoted } else { return false } })
    }

    /// A continuation paragraph of a list item gets no second bullet —
    /// including when a nested sublist came between it and the item.
    @Test func aContinuationAfterASublistKeepsItsBulletToItself() {
        let blocks = MarkdownBlocks.parse(
            """
            - outer item

              - inner item

              continuation of the outer item
            """)
        let markers = blocks.compactMap { block -> String? in
            if case .listItem(let marker, _) = block.kind { return marker }
            return nil
        }
        // One marker for the outer item, one for the inner, and nothing
        // for the continuation.
        #expect(markers.filter { !$0.isEmpty }.count == 2)
        #expect(markers.contains(""))
    }

    /// Foundation drops a newline inside a link label entirely, welding
    /// the words on either side of it together.
    @Test func aLinkLabelBrokenAcrossLinesKeepsItsSpace() {
        let blocks = MarkdownBlocks.parse(
            """
            See [the full
            report](https://example.com/x) for the rest.
            """)
        let text = blocks.map { String($0.content.characters) }.joined()
        #expect(text.contains("the full report"))
        #expect(!text.contains("fullreport"))

        // Image labels are the same shape, one "!" earlier.
        #expect(
            MarkdownBlocks.softenLabelBreaks("![a very\nwide diagram](/x.png)")
                == "![a very wide diagram](/x.png)")
        // Reference links close on "[" rather than "(".
        #expect(
            MarkdownBlocks.softenLabelBreaks("[the full\nreport][ref]")
                == "[the full report][ref]")
    }

    /// Fenced code can contain anything, and its newlines are the content.
    @Test func labelSofteningLeavesCodeAndProseAlone() {
        let fenced = """
            ```
            let x = [foo
            bar](baz)
            ```
            """
        #expect(MarkdownBlocks.softenLabelBreaks(fenced) == fenced)

        // An indented code block is code without a fence to say so.
        let indented = "Example:\n\n    let a = [foo\n    bar](baz)\n"
        #expect(MarkdownBlocks.softenLabelBreaks(indented) == indented)

        // Brackets that are not a link are prose.
        let prose = "a line ending in [TODO\nand the next line"
        #expect(MarkdownBlocks.softenLabelBreaks(prose) == prose)

        // Nothing to do, nothing done.
        #expect(MarkdownBlocks.softenLabelBreaks("plain text") == "plain text")
    }

    private func struck(_ attributed: AttributedString) -> String {
        attributed.runs
            .filter { $0.inlinePresentationIntent?.contains(.strikethrough) == true }
            .map { String(attributed[$0.range].characters) }
            .joined()
    }

    /// #32: two home-relative paths crossed out everything between them.
    /// `~/` has punctuation on both sides, so each tilde can open or close
    /// GFM's single-tilde strikethrough.
    @Test func homePathsAreNotStrikethrough() throws {
        for source in [
            "Both (~/a) and (~/b) exist.",
            "\"~/a\" and \"~/b\"",
            "x=~/a, y=~/b",
            "~/a/~/b",
        ] {
            // The bug is real: Foundation alone strikes these.
            let raw = try AttributedString(
                markdown: source, options: .init(interpretedSyntax: .full))
            #expect(!struck(raw).isEmpty, "no longer reproduces: \(source)")

            for syntax in [
                AttributedString.MarkdownParsingOptions.InterpretedSyntax.full,
                .inlineOnlyPreservingWhitespace,
            ] {
                let parsed = try #require(MarkdownBlocks.attributed(source, syntax: syntax))
                #expect(struck(parsed).isEmpty, "\(source)")
                #expect(String(parsed.characters) == source)
            }
        }

        let blocks = MarkdownBlocks.parse("Moved (~/src/a) to (~/src/b).")
        #expect(blocks.map(plain) == ["Moved (~/src/a) to (~/src/b)."])
    }

    /// Only the path tilde is guarded: deliberate strikethrough, fences,
    /// escapes and code all come through as Foundation gives them.
    @Test func tildeGuardingTouchesOnlyHomePaths() throws {
        let strike = try #require(
            MarkdownBlocks.attributed("a ~~gone~~ and ~also~ (~/kept)", syntax: .full))
        #expect(struck(strike) == "gonealso")
        #expect(String(strike.characters) == "a gone and also (~/kept)")

        // A tilde fence is three tildes, not three lone ones.
        let fence = MarkdownBlocks.parse("~~~\nls (~/a) (~/b)\n~~~")
        guard case .code = fence.first?.kind else {
            Issue.record("expected a code block, got \(String(describing: fence.first?.kind))")
            return
        }
        #expect(plain(fence[0]) == "ls (~/a) (~/b)")

        // Code spans keep their tildes and their backslashes.
        let code = try #require(
            MarkdownBlocks.attributed(#"`(~/a)` and `\~/b` (~/c)"#, syntax: .full))
        #expect(String(code.characters) == #"(~/a) and \~/b (~/c)"#)

        // An escaped tilde is already safe, and stays escaped.
        #expect(MarkdownBlocks.guardHomeTildes(#"(\~/a)"#) == #"(\~/a)"#)
        // An escaped backslash does not escape the tilde after it.
        #expect(
            MarkdownBlocks.guardHomeTildes(#"(\\~/a)"#)
                == "(\\\\\(MarkdownBlocks.tildeStandIn)/a)")
        // Nothing to guard, nothing done.
        #expect(MarkdownBlocks.guardHomeTildes("about ~5 minutes") == nil)
        // An author's own swung dash is never mistaken for a stand-in.
        #expect(MarkdownBlocks.guardHomeTildes("\u{2053} (~/a)") == nil)
    }

    /// The stand-in must come out everywhere the parser put it: styled
    /// runs keep their styling, and link destinations their tilde.
    @Test func restoredTildesKeepStylingAndLinks() throws {
        let bold = try #require(
            MarkdownBlocks.attributed("**see (~/a)** and (~/b)", syntax: .full))
        #expect(String(bold.characters) == "see (~/a) and (~/b)")
        let strong = bold.runs.filter {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(strong.map { String(bold[$0.range].characters) } == ["see (~/a)"])

        let link = try #require(
            MarkdownBlocks.attributed(
                "[home](https://example.com/~/x) and (~/b)", syntax: .full))
        let url = link.runs.compactMap(\.link).first
        #expect(url?.absoluteString == "https://example.com/~/x")
        #expect(!String(link.characters).contains(MarkdownBlocks.tildeStandIn))
    }
}
