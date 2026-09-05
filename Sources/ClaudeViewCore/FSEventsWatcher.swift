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
    /// Guards the check-and-clear in `stop()`. Two stops racing — a window
    /// closing while the last reference goes — would otherwise both see a
    /// stream and both release it.
    private let lock = NSLock()

    /// Marks the event queue so `stop()` can tell whether it is being
    /// called from inside *this* watcher's callback.
    ///
    /// The value is the watcher's identity, not a flag. Marked with a
    /// flag, any watcher's queue answered for every watcher: two windows
    /// mean two marked queues, and a stop called on the wrong one took the
    /// reentrant path and returned without waiting for its own in-flight
    /// callback — the exact guarantee this method is documented to keep.
    private static let queueMarker = DispatchSpecificKey<ObjectIdentifier>()
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

        FSEventStreamSetDispatchQueue(stream, queue)
        queue.setSpecific(key: Self.queueMarker, value: ObjectIdentifier(self))
        // A stream that fails to schedule is the failure this init exists
        // to report. Discarded, it handed back a watcher that looked live
        // and never fired: the sidebar would have gone quiet and fallen
        // back to its 15-second heartbeat with nothing to say why.
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    /// Safe from any thread, including the event queue itself.
    public func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        guard let stream else { return }

        FSEventStreamStop(stream)
        // Invalidate promises no further callbacks, but says nothing about
        // one already running. The queue is serial, so an empty sync block
        // returns only once that one has finished — and only then is it
        // safe to release the stream, which frees the handler box with it.
        FSEventStreamInvalidate(stream)

        if DispatchQueue.getSpecific(key: Self.queueMarker) == ObjectIdentifier(self) {
            // We are that callback. Waiting for it to finish is waiting
            // for ourselves — a reentrant sync on a serial queue, which is
            // a SIGTRAP, not a hang — and releasing here would free the
            // handler box out from under the call still running inside it.
            // "A handler that stops watching once it has seen what it came
            // for" is the natural way to write this, and it died.
            queue.async { FSEventStreamRelease(stream) }
        } else {
            queue.sync {}
            FSEventStreamRelease(stream)
        }
    }

    deinit {
        stop()
    }
}
