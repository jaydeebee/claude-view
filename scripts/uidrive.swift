// Drive the running app from a script: find its window, capture it, and
// send real mouse events to it.
//
// Built and run through `scripts/uidrive`, which caches the binary.
//
// The point of the `--in` flag is that coordinates become window-relative
// and, paired with `shot`, directly measurable: `shot` writes the window
// at exactly one pixel per point, so a coordinate read off the image is a
// coordinate you can click. Without that the caller is left converting
// between Retina pixels, a scaled-down screenshot, and screen points by
// hand, which is where this kind of script usually goes wrong.
//
// Events are posted through CGEvent rather than AppleScript on purpose:
// a SwiftUI List ignores `click at` and accessibility-set selection, and
// only moves for a real HID-level click.
//
// Needs Screen Recording (for capture) and Accessibility (for events) in
// System Settings › Privacy & Security, granted to whatever runs this.

import CoreGraphics
import Foundation

struct WindowInfo {
    let id: CGWindowID
    let owner: String
    let bounds: CGRect  // points, top-left origin
}

/// On-screen windows big enough to be real windows, optionally narrowed
/// to an owner name, frontmost first.
func windows(matching name: String?) -> [WindowInfo] {
    let listed =
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return listed.compactMap { window in
        guard let id = window[kCGWindowNumber as String] as? CGWindowID,
            let owner = window[kCGWindowOwnerName as String] as? String,
            let box = window[kCGWindowBounds as String] as? [String: CGFloat],
            let x = box["X"], let y = box["Y"],
            let width = box["Width"], let height = box["Height"],
            // Menu-bar extras and shadows are windows too; a real one is
            // bigger than any of them.
            width >= 200, height >= 200
        else { return nil }
        if let name, !owner.localizedCaseInsensitiveContains(name) { return nil }
        return WindowInfo(
            id: id, owner: owner,
            bounds: CGRect(x: x, y: y, width: width, height: height))
    }
}

func resolve(_ name: String?) -> WindowInfo? {
    guard let name else { return nil }
    guard let found = windows(matching: name).first else {
        FileHandle.standardError.write(Data("uidrive: no window matching '\(name)'\n".utf8))
        exit(1)
    }
    return found
}

/// A point in the coordinate space the caller asked for: window-relative
/// when `--in` named one, screen otherwise.
func screenPoint(x: Double, y: Double, in window: WindowInfo?) -> CGPoint {
    guard let window else { return CGPoint(x: x, y: y) }
    return CGPoint(x: window.bounds.minX + x, y: window.bounds.minY + y)
}

func post(_ event: CGEvent?) {
    event?.post(tap: .cghidEventTap)
    usleep(60_000)
}

func move(to point: CGPoint, _ source: CGEventSource?) {
    post(
        CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left))
    usleep(90_000)  // let hover settle before the press
}

func click(at point: CGPoint, right: Bool) {
    let source = CGEventSource(stateID: .hidSystemState)
    move(to: point, source)
    let (down, up, button) =
        right
        ? (CGEventType.rightMouseDown, CGEventType.rightMouseUp, CGMouseButton.right)
        : (CGEventType.leftMouseDown, CGEventType.leftMouseUp, CGMouseButton.left)
    post(
        CGEvent(
            mouseEventSource: source, mouseType: down, mouseCursorPosition: point,
            mouseButton: button))
    post(
        CGEvent(
            mouseEventSource: source, mouseType: up, mouseCursorPosition: point,
            mouseButton: button))
}

func scroll(at point: CGPoint, ticks: Int) {
    let source = CGEventSource(stateID: .hidSystemState)
    move(to: point, source)
    for _ in 0..<abs(ticks) {
        post(
            CGEvent(
                scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                wheel1: ticks > 0 ? 3 : -3, wheel2: 0, wheel3: 0))
    }
}

@discardableResult
func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// Capture one window at one pixel per point, so coordinates measured on
/// the image can be handed straight back to `click --in`.
func shot(_ window: WindowInfo, to path: String) {
    guard run("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(window.id)", path]) == 0,
        FileManager.default.fileExists(atPath: path)
    else {
        FileHandle.standardError.write(Data("uidrive: capture failed\n".utf8))
        exit(1)
    }
    // A Retina capture comes back at 2x. Resample the width explicitly:
    // `-Z` fits the *longest* side, so on a window taller than it is wide
    // it scales by height and the pixels-per-point promise quietly breaks.
    run("/usr/bin/sips", ["--resampleWidth", "\(Int(window.bounds.width))", path])
    print("\(path) \(Int(window.bounds.width))x\(Int(window.bounds.height)) @1pt/px")
}

// MARK: Argument handling

let usage = """
    usage: uidrive <command> [--in <app>]

      windows [name]              list on-screen windows: id, bounds, owner
      shot <path> --in <app>      capture one window at 1 pixel per point
      click <x> <y>               left click
      rclick <x> <y>              right click
      scroll <x> <y> <ticks>      scroll; negative ticks scroll down
      move <x> <y>                move the pointer only

    Coordinates are window-relative with --in, screen points without it.
    """

var argv = Array(CommandLine.arguments.dropFirst())
var target: String?
if let flag = argv.firstIndex(of: "--in"), flag + 1 < argv.count {
    target = argv[flag + 1]
    argv.removeSubrange(flag...(flag + 1))
}
guard let command = argv.first else {
    print(usage)
    exit(2)
}
let rest = Array(argv.dropFirst())

func number(_ index: Int) -> Double {
    guard index < rest.count, let value = Double(rest[index]) else {
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(2)
    }
    return value
}

switch command {
case "windows":
    let found = windows(matching: target ?? rest.first)
    if found.isEmpty {
        FileHandle.standardError.write(Data("uidrive: no windows matched\n".utf8))
        exit(1)
    }
    for window in found {
        let box = window.bounds
        print(
            "\(window.id)\t\(Int(box.minX)),\(Int(box.minY))"
                + "\t\(Int(box.width))x\(Int(box.height))\t\(window.owner)")
    }
case "shot":
    guard let path = rest.first else {
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(2)
    }
    guard let window = resolve(target) ?? windows(matching: nil).first else {
        FileHandle.standardError.write(Data("uidrive: no window to capture\n".utf8))
        exit(1)
    }
    shot(window, to: path)
case "click", "rclick":
    click(
        at: screenPoint(x: number(0), y: number(1), in: resolve(target)),
        right: command == "rclick")
case "scroll":
    scroll(
        at: screenPoint(x: number(0), y: number(1), in: resolve(target)),
        ticks: Int(number(2)))
case "move":
    move(
        to: screenPoint(x: number(0), y: number(1), in: resolve(target)),
        CGEventSource(stateID: .hidSystemState))
default:
    print(usage)
    exit(2)
}
