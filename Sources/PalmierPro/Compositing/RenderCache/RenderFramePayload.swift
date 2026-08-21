import CoreVideo
import Foundation

struct RenderFramePayload: Sendable, Equatable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: Data
    let attachments: Data

    var byteCount: Int { pixels.count + attachments.count + RenderFramePayload.headerLength }
}

extension RenderFramePayload {

    static let pixelFormat = kCVPixelFormatType_32BGRA
    static let headerLength = 28
    private static let magic: UInt32 = 0x5050_5243
    private static let version: UInt32 = 1

    static func payload(from buffer: CVPixelBuffer) -> RenderFramePayload? {
        guard CVPixelBufferGetPixelFormatType(buffer) == pixelFormat else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(buffer)
        let stride = width * 4
        guard sourceStride >= stride else { return nil }

        var pixels = Data(count: stride * height)
        pixels.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(target.advanced(by: row * stride), base.advanced(by: row * sourceStride), stride)
            }
        }
        return RenderFramePayload(
            width: width,
            height: height,
            bytesPerRow: stride,
            pixels: pixels,
            attachments: attachmentsData(from: buffer)
        )
    }

    func makeBuffer() -> CVPixelBuffer? {
        guard width > 0, height > 0, pixels.count >= bytesPerRow * height, bytesPerRow >= width * 4 else {
            return nil
        }
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, Self.pixelFormat,
            attributes as CFDictionary, &created
        ) == kCVReturnSuccess, let buffer = created else { return nil }

        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
        let copyLength = min(bytesPerRow, destinationStride)
        pixels.withUnsafeBytes { source in
            guard let origin = source.baseAddress else { return }
            for row in 0..<height {
                memcpy(base.advanced(by: row * destinationStride),
                       origin.advanced(by: row * bytesPerRow),
                       copyLength)
            }
        }
        Self.applyAttachments(attachments, to: buffer)
        return buffer
    }

    func encoded() -> Data {
        var data = Data(capacity: byteCount)
        appendLittleEndian(&data, Self.magic)
        appendLittleEndian(&data, Self.version)
        appendLittleEndian(&data, UInt32(width))
        appendLittleEndian(&data, UInt32(height))
        appendLittleEndian(&data, UInt32(bytesPerRow))
        appendLittleEndian(&data, UInt32(attachments.count))
        appendLittleEndian(&data, UInt32(pixels.count))
        data.append(attachments)
        data.append(pixels)
        return data
    }

    static func decoded(_ data: Data) -> RenderFramePayload? {
        guard data.count >= headerLength else { return nil }
        func field(_ index: Int) -> UInt32 {
            data.withUnsafeBytes { raw in raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) }
        }
        guard UInt32(littleEndian: field(0)) == magic, UInt32(littleEndian: field(1)) == version else {
            return nil
        }
        let width = Int(UInt32(littleEndian: field(2)))
        let height = Int(UInt32(littleEndian: field(3)))
        let bytesPerRow = Int(UInt32(littleEndian: field(4)))
        let attachmentsLength = Int(UInt32(littleEndian: field(5)))
        let pixelsLength = Int(UInt32(littleEndian: field(6)))
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              attachmentsLength >= 0, pixelsLength >= bytesPerRow * height,
              data.count == headerLength + attachmentsLength + pixelsLength else { return nil }
        let attachmentsStart = data.startIndex + headerLength
        let pixelsStart = attachmentsStart + attachmentsLength
        return RenderFramePayload(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixels: Data(data[pixelsStart..<(pixelsStart + pixelsLength)]),
            attachments: Data(data[attachmentsStart..<pixelsStart])
        )
    }

    private func appendLittleEndian(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func attachmentsData(from buffer: CVPixelBuffer) -> Data {
        guard let raw = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] else {
            return Data()
        }
        var storable: [String: Any] = [:]
        for (key, value) in raw where PropertyListSerialization.propertyList(value, isValidFor: .binary) {
            storable[key] = value
        }
        guard !storable.isEmpty else { return Data() }
        return (try? PropertyListSerialization.data(fromPropertyList: storable, format: .binary, options: 0))
            ?? Data()
    }

    private static func applyAttachments(_ data: Data, to buffer: CVPixelBuffer) {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let stored = plist as? [String: Any] else { return }
        for (key, value) in stored {
            CVBufferSetAttachment(buffer, key as CFString, value as CFTypeRef, .shouldPropagate)
        }
        if let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate),
           let colorSpace = CVImageBufferCreateColorSpaceFromAttachments(attachments) {
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey,
                                  colorSpace.takeRetainedValue(), .shouldPropagate)
        }
    }
}
