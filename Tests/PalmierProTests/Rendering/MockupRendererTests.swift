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

    @Test(arguments: ["mockup.iphone17", "mockup.macbook"])
    func registryExposesMockupEffect(id: String) {
        let descriptor = EffectRegistry.descriptor(id: id)
        #expect(descriptor != nil)
        #expect(descriptor?.params.map(\.key).sorted() == ["distance", "fov", "orbitPitch", "orbitYaw", "panX", "panY"])
        #expect(EffectRegistry.canonicalOrder.contains(id))
    }

    @Test(arguments: MockupRenderer.Device.allCases)
    func rendersDeviceWithTransparentSurround(device: MockupRenderer.Device) throws {
        let screen = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let pose = MockupRenderer.CameraPose(
            orbitYaw: 0, orbitPitch: 0, distance: 1.15, panX: 0, panY: 0, fov: 40
        )
        let extent = CGRect(x: 0, y: 0, width: 640, height: 360)
        let rendered = try #require(
            MockupRenderer.shared.render(device: device, screen: screen, pose: pose, extent: extent)
        )
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

    @Test(arguments: MockupRenderer.Device.allCases)
    func mapsScreenUprightAndUnmirrored(device: MockupRenderer.Device) throws {
        let extent = CGRect(x: 0, y: 0, width: 640, height: 360)
        let pose = MockupRenderer.CameraPose(
            orbitYaw: 0, orbitPitch: 0, distance: 1.15, panX: 0, panY: 0, fov: 40
        )
        let rendered = try #require(
            MockupRenderer.shared.render(
                device: device, screen: Self.quadrants(width: 1600, height: 1000), pose: pose, extent: extent
            )
        )

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func channels(dx: CGFloat, dy: CGFloat) -> [UInt8] {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(
                rendered, toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: 320 + dx, y: 180 + dy, width: 1, height: 1),
                format: .RGBA8, colorSpace: nil
            )
            return pixel
        }
        let topLeft = channels(dx: -38, dy: 21)
        let topRight = channels(dx: 38, dy: 21)
        let bottomLeft = channels(dx: -38, dy: -21)

        #expect(topLeft[0] > 150 && topLeft[1] < 100)
        #expect(topRight[1] > 150 && topRight[0] < 100)
        #expect(bottomLeft[2] > 150 && bottomLeft[0] < 100)
    }

    private static func quadrants(width: CGFloat, height: CGFloat) -> CIImage {
        func block(_ color: CIColor, _ x: CGFloat, _ y: CGFloat) -> CIImage {
            CIImage(color: color).cropped(
                to: CGRect(x: x * width / 2, y: y * height / 2, width: width / 2, height: height / 2)
            )
        }
        return block(.red, 0, 1)
            .composited(over: block(.green, 1, 1))
            .composited(over: block(.blue, 0, 0))
            .composited(over: block(CIColor(red: 1, green: 1, blue: 0), 1, 0))
    }
}
