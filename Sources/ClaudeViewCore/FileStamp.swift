import Foundation

/// Timestamps read by path.
///
/// `URL` memoizes its resource values: the first successful
/// `resourceValues(forKeys:)` on a URL value is answered from disk, and
/// every later one from that answer. A URL held across polls — kept in a
/// cache, stored on an actor, carried inside an index — therefore reports
/// the file as it was the first time it was asked, forever.
///
/// That is invisible in a test that stats a fresh URL and fatal in a
/// watcher: the timestamp a cache is keyed on stops moving, so the cache
/// never invalidates, so the thing it guards never updates. It has cost
/// this app two bugs in two files, which is why it is one function now.
public enum FileStamp {
    /// When the file was created and last written, or nil for each part
    /// the filesystem does not answer.
    public static func of(_ url: URL) -> (created: Date?, modified: Date?) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (
            attributes?[.creationDate] as? Date,
            attributes?[.modificationDate] as? Date
        )
    }

    /// Last write, or `.distantPast` when there is nothing to read — a
    /// file that cannot be statted has not changed.
    public static func modified(_ url: URL) -> Date {
        of(url).modified ?? .distantPast
    }
}
