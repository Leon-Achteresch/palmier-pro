import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Render verification needs the NSApplication event loop to composite host views.
enum MotionSceneBakeCommand {
    static func sceneURL(from arguments: [String]) -> URL? {
        value("--bake-motion-scene", in: arguments).map { URL(fileURLWithPath: $0) }
    }

    private static func value(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }

    @MainActor static func run(sceneURL: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        let directory = value("--motion-output-directory", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let requestedFrames = value("--motion-frames", in: arguments)
        Task { @MainActor in
            do {
                if let requestedFrames {
                    guard let directory else { throw MotionSceneError.invalidField("--motion-frames requires --motion-output-directory") }
                    let scene = try await MotionVideoGenerator.loadScene(at: sceneURL)
                    let parts = requestedFrames.split(separator: ",", omittingEmptySubsequences: false)
                    let frames = parts.compactMap { Int($0) }
                    guard frames.count == parts.count, (1...64).contains(frames.count), frames.allSatisfy({ (0..<scene.durationInFrames).contains($0) }) else {
                        throw MotionSceneError.invalidField("requested frames must be valid scene frame integers")
                    }
                    try await capture(scene: scene, frames: frames, directory: directory)
                }
                let start = ContinuousClock.now
                let video = try await MotionVideoGenerator.motionVideo(for: sceneURL, mediaRef: "bake-command", outputDirectory: directory)
                let summary = try await metadata(video)
                print("baked \(video.path)")
                print("\(summary) elapsed=\(start.duration(to: .now))")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("bake failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        app.run()
        exit(0)
    }

    @MainActor private static func capture(scene: MotionScene, frames: [Int], directory: URL) async throws {
        let renderer = try await MotionSceneRendererFactory.renderer(for: scene)
        defer { renderer.tearDown() }
        try await renderer.load(scene: scene)
        for (index, frame) in frames.enumerated() {
            let start = ContinuousClock.now
            try await renderer.seek(toMilliseconds: Double(frame) / scene.fps * 1000)
            let image = try await renderer.snapshot()
            let slots = try await renderer.slotBounds()
            try await write(image, slots: slots, to: directory.appendingPathComponent("frame-\(index)-\(frame).png"))
            print("frame=\(frame) elapsed=\(start.duration(to: .now))")
        }
    }

    @concurrent private static func write(_ image: CGImage, slots: [MotionSlotBounds], to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw MotionSceneError.writeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MotionSceneError.writeFailed }
        try JSONEncoder().encode(slots).write(to: url.deletingPathExtension().appendingPathExtension("slots.json"))
    }

    @concurrent private static func metadata(_ url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize) ?? .zero
        let duration = try await asset.load(.duration).seconds
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return "size=\(Int(size.width))x\(Int(size.height)) duration=\(String(format: "%.3f", duration))s bytes=\(bytes)"
    }
}
