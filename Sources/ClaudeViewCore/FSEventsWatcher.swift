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

    /// What the stream is given: the handler, boxed, and never the watcher
    /// itself. A callback firing on the event queue must not resurrect an
    /// object that may already be deallocating on another thread.
    private final class Delivery {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "claude-view.fsevents")

    public init?(paths: [String], latency: TimeInterval = 0.2, handler: @escaping Handler) {
        self.stream = nil
        let delivery = Delivery(handler)

        // Retain/release callbacks hand the box's lifetime to the stream,
        // so it outlives this initializer and dies with the stream.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(delivery).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(
                    Unmanaged<Delivery>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<Delivery>.fromOpaque(pointer).release()
            },
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let delivery = Unmanaged<Delivery>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            delivery.handler((cfPaths as? [String]) ?? [])
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

    /// Safe from any thread but the event queue itself — nothing on that
    /// queue holds the watcher, so nothing can call it from there.
    public func stop() {
        guard let stream else { return }
        self.stream = nil

        FSEventStreamStop(stream)
        // Invalidate promises no further callbacks, but says nothing about
        // one already running. The queue is serial, so an empty sync block
        // returns only once that one has finished — and only then is it
        // safe to release the stream, which frees the handler box with it.
        FSEventStreamInvalidate(stream)
        queue.sync {}
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }
}
