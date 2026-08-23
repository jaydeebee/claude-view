import Foundation

/// Claude Code logs terminal output exactly as printed — ANSI escapes and
/// all. The viewer is not a terminal, so display text sheds them.
public enum ANSIText {
    /// Removes ANSI escape sequences: CSI (`ESC[` through its final byte),
    /// OSC (`ESC]` through BEL or `ESC\`), and lone two-character escapes.
    /// Text without an ESC byte passes through untouched.
    public static func stripped(_ text: String) -> String {
        guard text.unicodeScalars.contains("\u{1B}") else { return text }
        var out = String.UnicodeScalarView()
        var rest = text.unicodeScalars[...]
        while let scalar = rest.first {
            rest = rest.dropFirst()
            guard scalar == "\u{1B}" else {
                out.append(scalar)
                continue
            }
            switch rest.first {
            case "[":  // CSI: parameter/intermediate bytes end at 0x40–0x7E
                rest = rest.dropFirst()
                while let c = rest.first {
                    rest = rest.dropFirst()
                    if (0x40...0x7E).contains(c.value) { break }
                }
            case "]":  // OSC: runs to BEL or the ESC-backslash terminator
                rest = rest.dropFirst()
                while let c = rest.first {
                    rest = rest.dropFirst()
                    if c == "\u{07}" { break }
                    if c == "\u{1B}", rest.first == "\\" {
                        rest = rest.dropFirst()
                        break
                    }
                }
            default:  // two-character escape (ESC c, ESC =, …)
                rest = rest.dropFirst()
            }
        }
        return String(out)
    }
}
