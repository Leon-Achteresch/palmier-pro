import Foundation

final class RenderFrameStore: @unchecked Sendable {

    static let cache = DiskCache(named: "RenderFrames")
    static let shared = RenderFrameStore(cache: cache, byteLimit: RenderCachePolicy.diskByteLimit)

    private struct Entry {
        let bytes: Int64
        var lastUse: UInt64
    }

    private let directory: URL
    private let byteLimit: Int64
    private let lock = NSLock()
    private var index: [RenderCacheKey: Entry]?
    private var totalBytes: Int64 = 0
    private var useCounter: UInt64 = 0

    init(cache: DiskCache, byteLimit: Int64) {
        self.directory = cache.directory
        self.byteLimit = max(0, byteLimit)
    }

    func contains(_ key: RenderCacheKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIndexIfNeeded()
        return index?[key] != nil
    }

    func payload(for key: RenderCacheKey) -> RenderFramePayload? {
        lock.lock()
        loadIndexIfNeeded()
        guard index?[key] != nil else {
            lock.unlock()
            return nil
        }
        useCounter &+= 1
        index?[key]?.lastUse = useCounter
        lock.unlock()

        guard let data = try? Data(contentsOf: url(for: key), options: [.mappedIfSafe]),
              let payload = RenderFramePayload.decoded(data) else {
            remove(key)
            return nil
        }
        return payload
    }

    @discardableResult
    func store(_ payload: RenderFramePayload, for key: RenderCacheKey) -> Bool {
        let data = payload.encoded()
        guard Int64(data.count) <= byteLimit else { return false }
        let destination = url(for: key)
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: staging, options: .atomic)
            try FileIO.moveReplacingDestination(from: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return false
        }

        lock.lock()
        loadIndexIfNeeded()
        if let existing = index?[key] { totalBytes -= existing.bytes }
        useCounter &+= 1
        index?[key] = Entry(bytes: Int64(data.count), lastUse: useCounter)
        totalBytes += Int64(data.count)
        let evictable = overflowKeys()
        lock.unlock()

        for key in evictable { remove(key) }
        return true
    }

    func byteCount() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        loadIndexIfNeeded()
        return totalBytes
    }

    func clear() {
        lock.lock()
        index = [:]
        totalBytes = 0
        lock.unlock()
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries { try? manager.removeItem(at: entry) }
    }

    func trim() {
        lock.lock()
        loadIndexIfNeeded()
        let evictable = overflowKeys()
        lock.unlock()
        for key in evictable { remove(key) }
    }

    @concurrent
    static func trimShared() async {
        shared.trim()
    }

    private func remove(_ key: RenderCacheKey) {
        lock.lock()
        if let removed = index?.removeValue(forKey: key) {
            totalBytes -= removed.bytes
        }
        lock.unlock()
        try? FileManager.default.removeItem(at: url(for: key))
    }

    private func overflowKeys() -> [RenderCacheKey] {
        guard let entries = index, totalBytes > byteLimit else { return [] }
        var remaining = totalBytes
        var doomed: [RenderCacheKey] = []
        for (key, entry) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            guard remaining > byteLimit else { break }
            doomed.append(key)
            remaining -= entry.bytes
        }
        return doomed
    }

    private func url(for key: RenderCacheKey) -> URL {
        directory.appendingPathComponent("\(key.storageName).ppframe", isDirectory: false)
    }

    private func loadIndexIfNeeded() {
        if index != nil { return }
        var entries: [RenderCacheKey: Entry] = [:]
        var bytes: Int64 = 0
        var counter: UInt64 = 0
        let manager = FileManager.default
        let contents = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in contents.sorted(by: { accessDate($0) < accessDate($1) }) {
            guard url.pathExtension == "ppframe",
                  let key = RenderCacheKey(storageName: url.deletingPathExtension().lastPathComponent) else {
                continue
            }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size > 0 else { continue }
            counter &+= 1
            entries[key] = Entry(bytes: size, lastUse: counter)
            bytes += size
        }
        useCounter = counter
        totalBytes = bytes
        index = entries
    }

    private func accessDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
    }
}
