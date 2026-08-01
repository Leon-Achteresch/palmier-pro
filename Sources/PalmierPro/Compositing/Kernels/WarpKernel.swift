import CoreImage
import Foundation

enum WarpKernel {
    private static let kernel = CIKernelLoader.kernel("Warp", "warpBendWave")

    static func apply(
        _ image: CIImage,
        extent: CGRect,
        bend: Double,
        waveAmplitude: Double,
        waveLength: Double,
        wavePhase: Double
    ) -> CIImage {
        let bend = bend.isFinite ? min(1, max(-1, bend)) : 0
        let amplitude = waveAmplitude.isFinite ? max(0, waveAmplitude) : 0
        guard bend != 0 || amplitude > 0 else { return image }
        guard extent.width > 0, extent.height > 0, let kernel else { return image }
        let maxShift = abs(bend) * extent.width * 0.25 + amplitude
        let rect = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.width, w: extent.height)
        return kernel.apply(
            extent: extent,
            roiCallback: { _, region in region.insetBy(dx: 0, dy: -maxShift - 1) },
            arguments: [
                image, rect, Float(bend), Float(amplitude),
                Float(max(1, waveLength)), Float(wavePhase * .pi / 180),
            ]
        ) ?? image
    }
}
