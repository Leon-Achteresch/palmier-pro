import CryptoKit
import Foundation

/// A React + Motion scene stored in the project package. The source is authored text; the rendered
/// video is a derived artifact keyed by `contentHash`.
struct MotionScene: Codable, Equatable, Sendable {
    static let fileExtension = "motion"
    static let currentVersion = 1

    static let maxSourceBytes = 512 * 1024
    static let dimensionRange = 16...4096
    static let fpsRange = 1.0...120.0
    static let frameCountRange = 1...36000

    var version: Int
    var width: Int
    var height: Int
    var fps: Double
    var durationInFrames: Int
    var source: String

    init(width: Int, height: Int, fps: Double, durationInFrames: Int, source: String) {
        self.version = Self.currentVersion
        self.width = width
        self.height = height
        self.fps = fps
        self.durationInFrames = durationInFrames
        self.source = source
    }

    var duration: Double { Double(durationInFrames) / fps }

    var size: CGSize { CGSize(width: width, height: height) }

    /// Stable across encodings so a re-saved but unchanged scene keeps its cached render.
    var contentHash: String {
        var hasher = SHA256()
        hasher.update(data: Data("\(version)|\(width)|\(height)|\(fps)|\(durationInFrames)|".utf8))
        hasher.update(data: Data(source.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func validated() throws -> MotionScene {
        guard version <= Self.currentVersion else {
            throw MotionSceneError.unsupportedVersion(version)
        }
        guard Self.dimensionRange.contains(width), Self.dimensionRange.contains(height) else {
            throw MotionSceneError.invalidField(
                "width/height must be \(Self.dimensionRange.lowerBound)–\(Self.dimensionRange.upperBound); got \(width)x\(height)"
            )
        }
        guard fps.isFinite, Self.fpsRange.contains(fps) else {
            throw MotionSceneError.invalidField("fps must be \(Self.fpsRange.lowerBound)–\(Self.fpsRange.upperBound); got \(fps)")
        }
        guard Self.frameCountRange.contains(durationInFrames) else {
            throw MotionSceneError.invalidField(
                "durationInFrames must be \(Self.frameCountRange.lowerBound)–\(Self.frameCountRange.upperBound); got \(durationInFrames)"
            )
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MotionSceneError.invalidField("source is empty")
        }
        guard source.utf8.count <= Self.maxSourceBytes else {
            throw MotionSceneError.invalidField("source is \(source.utf8.count) bytes; max \(Self.maxSourceBytes)")
        }
        return self
    }

    /// Encoder dimensions must be even, so a scene is authored at its declared size and encoded at
    /// the nearest even one rather than being silently rescaled.
    var encodedSize: CGSize {
        CGSize(width: width - width % 2, height: height - height % 2)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> MotionScene {
        guard data.count <= maxSourceBytes * 2 else {
            throw MotionSceneError.invalidField("scene file is too large (\(data.count) bytes)")
        }
        let scene: MotionScene
        do {
            scene = try JSONDecoder().decode(MotionScene.self, from: data)
        } catch {
            throw MotionSceneError.malformed(error.localizedDescription)
        }
        return try scene.validated()
    }

    /// Cheap sniff for import validation; mirrors `LottieVideoGenerator.isLottie(at:)`.
    nonisolated static func isMotionScene(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == fileExtension,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return false }
        return (try? decoded(from: data)) != nil
    }
}

enum MotionSceneError: LocalizedError, Equatable {
    case runtimeMissing
    case unsupportedVersion(Int)
    case invalidField(String)
    case malformed(String)
    case sceneFailed(String)
    case renderTimedOut
    case snapshotFailed
    case writeFailed
    case pixelBufferCreationFailed
    case appendFailed(frame: Int)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing: "the bundled motion runtime is missing"
        case .unsupportedVersion(let version): "scene version \(version) is newer than this app supports"
        case .invalidField(let detail): "invalid scene: \(detail)"
        case .malformed(let detail): "could not read scene: \(detail)"
        case .sceneFailed(let detail): detail
        case .renderTimedOut: "the scene did not finish rendering in time"
        case .snapshotFailed: "could not capture a frame from the scene"
        case .writeFailed: "could not write motion video"
        case .pixelBufferCreationFailed: "could not create pixel buffer"
        case .appendFailed(let frame): "could not append motion frame \(frame)"
        }
    }
}
