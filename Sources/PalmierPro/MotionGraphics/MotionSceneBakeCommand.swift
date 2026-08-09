import AVFoundation
import AppKit
import Foundation

/// Bakes one scene and exits. Offscreen compositing needs a running NSApplication, which the SwiftPM
/// test process has none of, so end-to-end render coverage runs through the app binary instead.
enum MotionSceneBakeCommand {
    static func sceneURL(from arguments: [String]) -> URL? {
        guard let flag = arguments.firstIndex(of: "--bake-motion-scene"),
              arguments.index(after: flag) < arguments.endIndex
        else { return nil }
        return URL(fileURLWithPath: arguments[arguments.index(after: flag)])
    }

    static func run(sceneURL: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task { @MainActor in
            do {
                let video = try await MotionVideoGenerator.motionVideo(for: sceneURL, mediaRef: "bake-command")
                let asset = AVURLAsset(url: video)
                let track = try await asset.loadTracks(withMediaType: .video).first
                let size = try await track?.load(.naturalSize) ?? .zero
                let duration = try await asset.load(.duration).seconds
                let bytes = (try? FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0

                print("baked \(video.path)")
                print("size=\(Int(size.width))x\(Int(size.height)) duration=\(String(format: "%.3f", duration))s bytes=\(bytes)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("bake failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }

        app.run()
        exit(0)
    }
}
