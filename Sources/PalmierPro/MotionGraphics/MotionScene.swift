import AVFoundation
import CryptoKit
import Foundation

/// Which runtime renders a scene. `web` is React + Motion + shadcn in a WKWebView; `reactNative`
/// is react-native-macos rendering real RN views through Fabric and Yoga.
enum MotionSceneRuntime: String, Codable, Equatable, Sendable, CaseIterable {
    case web
    case reactNative = "react-native"

    var isAvailable: Bool {
        #if REACT_NATIVE
        true
        #else
        self == .web
        #endif
    }
}

struct MotionScene: Codable, Equatable, Sendable {
    static let fileExtension = "motion"
    static let currentVersion = 2
    static let rendererVersion = "structured-4-frame-contract"
    static let timeScale: CMTimeScale = 600000
    static let maxSourceBytes = 16 * 1024 * 1024
    static let maxDocumentBytes = 64 * 1024 * 1024
    static let dimensionRange = 16...4096
    static let fpsRange = 1.0...120.0
    static let frameCountRange = 1...36000

    var version: Int = currentVersion
    var id: String = UUID().uuidString
    var revision: Int = 0
    var width: Int
    var height: Int
    var fps: Double
    var durationInFrames: Int
    var runtime: MotionSceneRuntime = .web
    var components: [MotionComponent] = []
    var nodes: [MotionNode] = []
    var audioCues: [MotionAudioCue] = []
    var sounds: [String: MotionAudioSource] = [:]
    var formats: [MotionFormat] = []
    var background: String = "transparent"

    init(width: Int, height: Int, fps: Double, durationInFrames: Int, runtime: MotionSceneRuntime = .web) {
        self.width = width
        self.height = height
        self.fps = fps
        self.durationInFrames = durationInFrames
        self.runtime = runtime
    }

    init(width: Int, height: Int, fps: Double, durationInFrames: Int, source: String, runtime: MotionSceneRuntime = .web) {
        self.init(width: width, height: height, fps: fps, durationInFrames: durationInFrames, runtime: runtime)
        id = "scene"
        components = [MotionComponent(id: "component", name: "Scene", source: source)]
        nodes = [MotionNode(id: "root", name: "Scene", kind: .component, componentID: "component", durationFrames: durationInFrames,
                            properties: ["width": .number(Double(width)), "height": .number(Double(height))])]
    }

    var duration: Double { Double(durationInFrames) / fps }
    var size: CGSize { CGSize(width: width, height: height) }
    var encodedSize: CGSize { CGSize(width: width - width % 2, height: height - height % 2) }

    var contentHash: String {
        get throws {
        var snapshot = self
        snapshot.revision = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        var hasher = SHA256()
        hasher.update(data: Data(Self.rendererVersion.utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    func time(forFrame frame: Int) -> CMTime { CMTime(seconds: Double(frame) / fps, preferredTimescale: Self.timeScale) }

    @concurrent func runtimeJSON() async throws -> String {
        var snapshot = try validated()
        snapshot.sounds = [:]
        snapshot.audioCues = []
        return String(decoding: try snapshot.encoded(), as: UTF8.self)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> MotionScene {
        guard data.count <= maxDocumentBytes else { throw MotionSceneError.invalidField("scene file is too large") }
        struct Header: Decodable { var version: Int }
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == currentVersion else { throw MotionSceneError.unsupportedVersion(header.version) }
            return try decoder.decode(MotionScene.self, from: data).validated()
        } catch let error as MotionSceneError { throw error }
        catch { throw MotionSceneError.malformed(error.localizedDescription) }
    }

    nonisolated static func isMotionScene(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == fileExtension,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return (try? decoded(from: data)) != nil
    }
}

enum MotionSceneError: LocalizedError, Equatable {
    case runtimeMissing
    case reactNativeUnavailable
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
        case .reactNativeUnavailable: "this build does not include the React Native runtime"
        case .unsupportedVersion(let version): "unsupported scene version \(version); expected \(MotionScene.currentVersion)"
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
