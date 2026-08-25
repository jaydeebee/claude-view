import Foundation

/// The command line that reopens a session in the terminal.
///
/// Claude Code resumes by session id, so the id alone is enough to type;
/// the command exists because that is what the id is *for*, and building
/// it here keeps the shell quoting in one tested place rather than in a
/// menu handler.
public enum ResumeCommand {
    /// `claude --resume` looks for the session under the directory it is
    /// run from, so the command carries the `cd` whenever the directory is
    /// known — pasted anywhere, it lands in the right place. Without one,
    /// it is the bare resume and the reader is on their own.
    public static func text(sessionId: String, directory: String? = nil) -> String {
        let resume = "claude --resume \(shellQuoted(sessionId))"
        guard let directory, !directory.isEmpty else { return resume }
        return "cd \(shellQuoted(directory)) && \(resume)"
    }

    /// A session id is a UUID today, but it reaches us from a filename we
    /// do not control, so it is quoted like any other untrusted string.
    /// Bare when it is plainly safe, single-quoted otherwise, with the
    /// POSIX `'\''` dance for embedded quotes.
    static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
