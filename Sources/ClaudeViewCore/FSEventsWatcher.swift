import CoreServices
import Foundation

/// Thin wrapper over an FSEventStream: recursive, coalesced directory
/// watching for `~/.claude/projects` and `~/.claude/sessions`.
///
/// FSEvents is the wake-up call, not the data: on any event the stores
/// re-poll the files they care about. The handler runs on an internal
/// queue; consumers hop to the main actor themselves.
public final class FSEventsWatcher {
    public typealias Handler = ([String]) -> Void

    private var stream: FSEventStreamRef?
    private let handler: Handler
    private let queue = DispatchQueue(label: "claude-view.fsevents")

    public init?(paths: [String], latency: TimeInterval = 0.2, handler: @escaping Handler) {
        self.handler = handler
        self.stream = nil

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let paths = (cfPaths as? [String]) ?? []
            watcher.handler(paths)
        }

        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
