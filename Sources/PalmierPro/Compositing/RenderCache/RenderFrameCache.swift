import CoreVideo
import Foundation

final class RenderFrameCache: @unchecked Sendable {

    static let shared = RenderFrameCache(byteLimit: RenderCachePolicy.memoryByteLimit)

    private struct Entry {
        let buffer: CVPixelBuffer
        let bytes: Int
        var lastUse: UInt64
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private var entries: [RenderCacheKey: Entry] = [:]
    private var totalBytes = 0
    private var useCounter: UInt64 = 0

    init(byteLimit: Int) {
        self.byteLimit = max(0, byteLimit)
    }

    func frame(for key: RenderCacheKey, size: CGSize) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard CVPixelBufferGetWidth(entry.buffer) == Int(size.width.rounded()),
              CVPixelBufferGetHeight(entry.buffer) == Int(size.height.rounded()) else { return nil }
        useCounter &+= 1
        entries[key]?.lastUse = useCounter
        return entry.buffer
    }

    func contains(_ key: RenderCacheKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key] != nil
    }

    func store(_ buffer: CVPixelBuffer, for key: RenderCacheKey) {
        let bytes = CVPixelBufferGetDataSize(buffer)
        guard bytes > 0, bytes <= byteLimit else { return }
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries.removeValue(forKey: key) {
            totalBytes -= existing.bytes
        }
        useCounter &+= 1
        entries[key] = Entry(buffer: buffer, bytes: bytes, lastUse: useCounter)
        totalBytes += bytes
        evictLeastRecentlyUsed()
    }

    func retain(digests: Set<UInt64>) {
        lock.lock()
        defer { lock.unlock() }
        for (key, entry) in entries where !digests.contains(key.spanDigest) {
            entries.removeValue(forKey: key)
            totalBytes -= entry.bytes
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        totalBytes = 0
    }

    var statistics: (spans: Int, frames: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        var spans = Set<UInt64>()
        for key in entries.keys { spans.insert(key.spanDigest) }
        return (spans.count, entries.count, totalBytes)
    }

    private func evictLeastRecentlyUsed() {
        guard totalBytes > byteLimit else { return }
        for key in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }).map(\.key) {
            guard totalBytes > byteLimit else { return }
            if let removed = entries.removeValue(forKey: key) {
                totalBytes -= removed.bytes
            }
        }
    }
}
