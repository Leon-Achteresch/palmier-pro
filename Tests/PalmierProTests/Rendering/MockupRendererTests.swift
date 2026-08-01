import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("Device mockup")
struct MockupRendererTests {

    @Test func projectFileRoundTripsEnabledAddons() throws {
        var file = ProjectFile(
            timelines: [Fixtures.timeline()],
            activeTimelineId: nil,
            openTimelineIds: nil,
            enabledAddons: [ProjectAddon.deviceMockups]
        )
        let decoded = try ProjectFile.decode(try JSONEncoder().encode(file))
        #expect(decoded.enabledAddons == [ProjectAddon.deviceMockups])

        file.enabledAddons = nil
        let legacy = try ProjectFile.decode(try JSONEncoder().encode(file))
        #expect(legacy.enabledAddons == nil)
    }

    @Test func registryExposesMockupEffect() {
        let descriptor = EffectRegistry.descriptor(id: "mockup.iphone17")
        #expect(descriptor != nil)
        #expect(descriptor?.params.map(\.key).sorted() == ["distance", "fov", "orbitPitch", "orbitYaw", "panX", "panY"])
        #expect(EffectRegistry.canonicalOrder.contains("mockup.iphone17"))
    }

    @Test func rendersPhoneWithTransparentSurround() throws {
        let screen = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let pose = MockupRenderer.CameraPose(
            orbitYaw: 0, orbitPitch: 0, distance: 1.15, panX: 0, panY: 0, fov: 40
        )
        let extent = CGRect(x: 0, y: 0, width: 640, height: 360)
        let rendered = try #require(MockupRenderer.shared.render(screen: screen, pose: pose, extent: extent))
        #expect(rendered.extent == extent)

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            rendered, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 2, y: 2, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )
        #expect(pixel[3] == 0)

        context.render(
            rendered, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 320, y: 180, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )
        #expect(pixel[3] > 200)
        #expect(pixel[1] > 100)
    }
}
