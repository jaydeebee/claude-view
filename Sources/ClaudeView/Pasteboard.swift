import AppKit

/// Puts a plain string on the general pasteboard, replacing what was there.
func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
