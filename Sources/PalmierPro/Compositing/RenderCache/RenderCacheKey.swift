import Foundation

struct RenderCacheKey: Hashable, Sendable {
    let spanDigest: UInt64
    let frame: Int

    var storageName: String { String(format: "%016llx-%d", spanDigest, frame) }

    init(spanDigest: UInt64, frame: Int) {
        self.spanDigest = spanDigest
        self.frame = frame
    }

    init?(storageName: String) {
        let parts = storageName.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let digest = UInt64(parts[0], radix: 16),
              let frame = Int(parts[1]) else { return nil }
        self.spanDigest = digest
        self.frame = frame
    }
}

struct RenderCacheSpan: Sendable, Equatable {
    let digest: UInt64
    let frames: Range<Int>
}

struct RenderCacheStatus: Sendable, Equatable {
    var cachedSpans = 0
    var cachedFrames = 0
    var memoryBytes = 0
    var diskBytes: Int64 = 0
    var isWarming = false
}

struct StableDigest {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            value ^= UInt64(byte)
            value &*= 0x100_0000_01b3
        }
    }

    mutating func combine(_ data: Data) {
        data.withUnsafeBytes { raw in
            for byte in raw {
                value ^= UInt64(byte)
                value &*= 0x100_0000_01b3
            }
        }
    }

    mutating func combine(_ string: String) {
        combine(Array(string.utf8))
        combine(UInt8(0))
    }

    mutating func combine(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= 0x100_0000_01b3
    }

    mutating func combine(_ number: Int) {
        withUnsafeBytes(of: Int64(number).littleEndian) { combine($0) }
    }

    mutating func combine(_ number: Int32) {
        withUnsafeBytes(of: number.littleEndian) { combine($0) }
    }

    mutating func combine(_ number: Double) {
        let normalized = number.isFinite ? number : 0
        withUnsafeBytes(of: normalized.bitPattern.littleEndian) { combine($0) }
    }

    mutating func combine(_ flag: Bool) {
        combine(UInt8(flag ? 1 : 0))
    }

    mutating func combine(_ size: CGSize) {
        combine(Double(size.width))
        combine(Double(size.height))
    }

    mutating func combine(_ transform: CGAffineTransform) {
        combine(Double(transform.a))
        combine(Double(transform.b))
        combine(Double(transform.c))
        combine(Double(transform.d))
        combine(Double(transform.tx))
        combine(Double(transform.ty))
    }
}
