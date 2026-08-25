import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct ResumeCommandTests {
    @Test func aSessionIdIsPastableAsIs() {
        #expect(
            ResumeCommand.text(sessionId: "153c52d1-1ab3-4412-a663-32872cee4243")
                == "claude --resume 153c52d1-1ab3-4412-a663-32872cee4243")
    }

    /// Ids come from filenames, not from us. Anything that could end the
    /// argument early gets quoted rather than pasted into someone's shell.
    @Test func anythingUnusualIsQuoted() {
        #expect(ResumeCommand.shellQuoted("abc-123_x.y/z") == "abc-123_x.y/z")
        #expect(ResumeCommand.shellQuoted("a b") == "'a b'")
        #expect(ResumeCommand.shellQuoted("") == "''")
        #expect(ResumeCommand.shellQuoted("a;rm -rf /") == "'a;rm -rf /'")
        #expect(ResumeCommand.shellQuoted("a$(id)") == "'a$(id)'")
        #expect(ResumeCommand.shellQuoted("it's") == #"'it'\''s'"#)
    }

    /// The quoted form has to survive the shell it is pasted into, so
    /// check it round-trips through one rather than trusting the shape.
    @Test func theQuotedFormSurvivesARealShell() throws {
        for value in ["plain-id", "a b", "it's", "a;echo pwned", "a$(id)", "x'y\"z"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s \(ResumeCommand.shellQuoted(value))"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(String(data: data, encoding: .utf8) == value)
        }
    }
}
