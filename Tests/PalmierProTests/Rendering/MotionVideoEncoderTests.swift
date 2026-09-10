import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

@Suite("Motion video alpha")
struct MotionVideoEncoderTests {
    @Test(arguments: [0.25, 0.5, 1.0])
    func exportPreservesCompositedColor(alpha: Double) async throws {
        let package = try await MotionTestPackage.make()
        do {
            let image = try Self.image(alpha: alpha)
            let output = package.url.appendingPathComponent("alpha.mov")
            let encoder = MotionVideoEncoder(target: CGSize(width: 32, height: 32), output: output)
            try await encoder.start()
            try await encoder.append(image, at: .zero, frame: 0)
            let scene = MotionScene(width: 32, height: 32, fps: 30, durationInFrames: 1)
            try await encoder.finish(scene: scene, endTime: scene.time(forFrame: 1))
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            let decoded = try await generator.image(at: .zero).image
            let expected = try Self.pixel(image), actual = try Self.pixel(decoded)
            #expect(zip(expected, actual).allSatisfy { abs(Int($0) - Int($1)) <= 3 })
            try await package.remove()
        } catch { try await package.remove(); throw error }
    }

    private static func context() throws -> CGContext {
        try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private static func image(alpha: Double) throws -> CGImage {
        let context = try context()
        context.setFillColor(red: 0.9, green: 0.4, blue: 0.2, alpha: alpha)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return try #require(context.makeImage())
    }

    private static func pixel(_ image: CGImage) throws -> [UInt8] {
        let context = try context()
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes.advanced(by: 16 * 128 + 16 * 4), count: 4))
    }
}
