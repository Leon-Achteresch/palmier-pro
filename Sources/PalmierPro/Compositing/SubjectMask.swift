import CoreImage
import CoreVideo
import Foundation
import Vision

/// Vision-driven subject isolation: cuts the person (or salient subject) out of a frame
/// and returns it with everything else transparent, so lower tracks show through.
enum SubjectMask {

    enum Quality: Int, Sendable {
        case fast = 0, balanced = 1, subject = 2

        init(param: Double) {
            self = Quality(rawValue: Int(param.rounded())) ?? .balanced
        }

        var personLevel: VNGeneratePersonSegmentationRequest.QualityLevel? {
            switch self {
            case .fast: .fast
            case .balanced: .balanced
            case .subject: nil
            }
        }
    }

    /// Reuses one Vision request per quality level — building them per frame would load a model
    /// inside the render loop. Vision requests are not thread-safe, so calls serialize here.
    private final class RequestPool: @unchecked Sendable {
        private let lock = NSLock()
        private var person: [VNGeneratePersonSegmentationRequest.QualityLevel: VNGeneratePersonSegmentationRequest] = [:]
        private lazy var foreground = VNGenerateForegroundInstanceMaskRequest()

        func maskBuffer(for image: CIImage, quality: Quality) -> CVPixelBuffer? {
            lock.lock()
            defer { lock.unlock() }
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            if let level = quality.personLevel {
                let request = person[level] ?? {
                    let r = VNGeneratePersonSegmentationRequest()
                    r.qualityLevel = level
                    r.outputPixelFormat = kCVPixelFormatType_OneComponent8
                    person[level] = r
                    return r
                }()
                guard (try? handler.perform([request])) != nil,
                      let buffer = request.results?.first?.pixelBuffer,
                      Self.containsSubject(buffer) else { return nil }
                return buffer
            }
            guard (try? handler.perform([foreground])) != nil,
                  let observation = foreground.results?.first,
                  !observation.allInstances.isEmpty else { return nil }
            return try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        }

        /// Person segmentation always returns a buffer, empty when it found nobody. Sampling the
        /// small mask on the CPU beats a GPU reduction with a readback stall in the render loop.
        private static func containsSubject(_ buffer: CVPixelBuffer) -> Bool {
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in Swift.stride(from: 0, to: height, by: 4) {
                let row = bytes + y * stride
                for x in Swift.stride(from: 0, to: width, by: 4) where row[x] >= 128 {
                    return true
                }
            }
            return false
        }
    }

    private static let pool = RequestPool()

    /// Returns `image` with only the subject opaque. Falls back to the untouched image when
    /// Vision finds nothing, so a missed detection never blanks the frame.
    static func apply(
        _ image: CIImage,
        extent: CGRect,
        quality: Double,
        feather: Double,
        expand: Double,
        invert: Double
    ) -> CIImage {
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite, !extent.isNull else { return image }
        let source = image.extent.isInfinite ? image.cropped(to: extent) : image
        guard let buffer = pool.maskBuffer(for: source, quality: Quality(param: quality)) else { return image }

        var mask = CIImage(cvPixelBuffer: buffer)
        if mask.extent.width > 0, mask.extent.height > 0 {
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: extent.width / mask.extent.width,
                y: extent.height / mask.extent.height
            ))
        }
        mask = mask.transformed(by: CGAffineTransform(translationX: extent.minX - mask.extent.minX,
                                                      y: extent.minY - mask.extent.minY))

        let shortEdge = min(extent.width, extent.height)
        let growRadius = abs(expand) * shortEdge * 0.02
        if growRadius >= 1 {
            mask = mask.applyingFilter(
                expand > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum",
                parameters: ["inputRadius": growRadius]
            )
        }
        let featherRadius = feather * shortEdge * 0.03
        if featherRadius >= 0.5 {
            mask = mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: featherRadius])
        }
        if invert >= 0.5 {
            mask = mask.applyingFilter("CIColorInvert")
        }
        mask = mask.cropped(to: extent)

        return source
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputMaskImageKey: mask,
                kCIInputBackgroundImageKey: CIImage.empty(),
            ])
            .cropped(to: extent)
    }
}
