import AVFoundation
import Accelerate
import CoreGraphics
import CoreVideo

actor MotionVideoEncoder {
    private let target: CGSize
    private let output: URL
    private var temporary: URL?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    init(target: CGSize, output: URL) { self.target = target; self.output = output }

    func start() throws {
        try Task.checkCancellation()
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".motion-\(UUID().uuidString).mov")
        self.temporary = temporary
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        self.writer = writer
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: Int(target.width), AVVideoHeightKey: Int(target.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        input.expectsMediaDataInRealTime = false
        self.input = input
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(target.width), kCVPixelBufferHeightKey as String: Int(target.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw MotionSceneError.writeFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MotionSceneError.writeFailed }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage, at time: CMTime, frame: Int) async throws {
        try Task.checkCancellation()
        guard let writer, let input, let adaptor, let pool = adaptor.pixelBufferPool else { throw MotionSceneError.writeFailed }
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? MotionSceneError.writeFailed }
            try await Task.sleep(for: .milliseconds(5))
        }
        try autoreleasepool {
            var output: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let buffer = output else { throw MotionSceneError.pixelBufferCreationFailed }
            try Self.draw(image, into: buffer, target: target)
            guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? MotionSceneError.appendFailed(frame: frame) }
        }
    }

    func finish(scene: MotionScene, endTime: CMTime) async throws {
        try Task.checkCancellation()
        guard let writer, let input, let temporary else { throw MotionSceneError.writeFailed }
        writer.endSession(atSourceTime: endTime)
        input.markAsFinished()
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? MotionSceneError.writeFailed }
        try await MotionSceneAudio.installSound(in: temporary, scene: scene)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: output) }
        self.temporary = nil
        self.writer = nil
        self.input = nil
        adaptor = nil
    }

    func cancel() {
        writer?.cancelWriting()
        writer = nil; input = nil; adaptor = nil
        if let temporary {
            do { try FileManager.default.removeItem(at: temporary) }
            catch { Log.preview.warning("motion encoder temporary cleanup failed: \(Log.detail(error))") }
        }
        temporary = nil
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, target: CGSize) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(target.width), height: Int(target.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw MotionSceneError.pixelBufferCreationFailed }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
        let rect = CGRect(origin: .zero, size: target)
        context.clear(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        var pixels = vImage_Buffer(data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(target.height),
            width: vImagePixelCount(target.width), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        var destination = pixels
        guard vImageUnpremultiplyData_RGBA8888(&pixels, &destination, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw MotionSceneError.pixelBufferCreationFailed
        }
    }
}
