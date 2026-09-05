import Foundation

/// Claude Code logs terminal output exactly as printed — ANSI escapes and
/// all. The viewer is not a terminal, so display text sheds them.
public enum ANSIText {
    /// Removes ANSI escape sequences: CSI (`ESC[` through its final byte),
    /// the string-terminated ones (OSC, DCS, SOS, PM, APC — through BEL or
    /// `ESC\`), and shorter escapes, which are two characters only when
    /// they carry no intermediate bytes. Text without an ESC byte passes
    /// through untouched.
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
            // OSC, DCS, SOS, PM, APC all run to a string terminator.
            // Treating the last four as two-character escapes left their
            // entire payload in the text.
            case "]", "P", "X", "^", "_":
                rest = rest.dropFirst()
                while let c = rest.first {
                    rest = rest.dropFirst()
                    if c == "\u{07}" { break }
                    if c == "\u{1B}", rest.first == "\\" {
                        rest = rest.dropFirst()
                        break
                    }
                }
            default:
                // ESC, then any run of intermediate bytes (0x20–0x2F),
                // then one final byte (0x30–0x7E). Dropping a single
                // scalar handled `ESC c` and `ESC =` and mangled the rest:
                // `ESC ( B` is the first half of terminfo's sgr0 on this
                // machine, so every `!` command whose output reset its
                // attributes left a stray "B" in the console row.
                while let c = rest.first, (0x20...0x2F).contains(c.value) {
                    rest = rest.dropFirst()
                }
                if let c = rest.first, (0x30...0x7E).contains(c.value) {
                    rest = rest.dropFirst()
                }
            }
        }
        return String(out)
    }
}
