import AppKit
import CoreImage
import SceneKit

final class MockupRenderer: @unchecked Sendable {
    static let shared = MockupRenderer()

    enum Device: String, CaseIterable, Sendable {
        case iPhone17Pro
        case macBookUltra

        var resource: String {
            switch self {
            case .iPhone17Pro: "Mockups/iPhone17Pro.usdz"
            case .macBookUltra: "Mockups/MacBookUltra.usdz"
            }
        }

        var screenMaterial: String {
            switch self {
            case .iPhone17Pro: "Screen_BG"
            case .macBookUltra: "material"
            }
        }

        /// Materials on geometry coplanar with the screen, which would z-fight with it.
        var occludingMaterials: Set<String> {
            switch self {
            case .iPhone17Pro: []
            case .macBookUltra: ["Display_glass_nanotexture"]
            }
        }
    }

    struct CameraPose {
        let orbitYaw: Double
        let orbitPitch: Double
        let distance: Double
        let panX: Double
        let panY: Double
        let fov: Double
    }

    private struct Rig {
        let renderer: SCNRenderer
        let screenMaterial: SCNMaterial
        let pivot: SCNNode
        let cameraNode: SCNNode
        let camera: SCNCamera
        let radius: CGFloat
        let screenAspect: CGFloat
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
    }

    private let lock = NSLock()
    private var rigs: [Device: Rig?] = [:]
    private var screenTextures: [Device: MTLTexture] = [:]
    private var msaaTexture: MTLTexture?
    private var outputPool: CVPixelBufferPool?
    private var outputSize: (width: Int, height: Int) = (0, 0)
    private var textureCache: CVMetalTextureCache?

    func render(device: Device, screen: CIImage, pose: CameraPose, extent: CGRect) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        if rigs[device] == nil { rigs[device] = loadRig(device) }
        guard let rig = rigs[device] ?? nil else { return nil }

        let cropped = Self.centerCropped(screen, toAspect: rig.screenAspect)
        var uploaded = false
        Self.commit {
            uploaded = uploadScreen(cropped, device: device, rig: rig)

            rig.camera.fieldOfView = pose.fov
            rig.pivot.eulerAngles = SCNVector3(
                -pose.orbitPitch * .pi / 180,
                pose.orbitYaw * .pi / 180,
                0
            )
            let dist = rig.radius / tan(CGFloat(pose.fov) * .pi / 360) * CGFloat(pose.distance)
            rig.cameraNode.position = SCNVector3(
                -CGFloat(pose.panX) * rig.radius,
                -CGFloat(pose.panY) * rig.radius,
                dist
            )
        }
        guard uploaded else { return nil }

        let renderSize = Self.boundedRenderSize(extent.size)
        guard let output = renderScene(rig, size: renderSize) else { return nil }
        var image = CIImage(cvPixelBuffer: output)
        let scale = extent.width / image.extent.width
        if scale != 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return image.transformed(by: CGAffineTransform(
            translationX: extent.origin.x - image.extent.origin.x,
            y: extent.origin.y - image.extent.origin.y
        )).cropped(to: extent)
    }

    private func uploadScreen(_ image: CIImage, device: Device, rig: Rig) -> Bool {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return false }
        let scale = min(1, 2048 / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        if screenTextures[device].map({ $0.width != width || $0.height != height }) ?? true {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            screenTextures[device] = rig.device.makeTexture(descriptor: descriptor)
        }
        guard let screenTexture = screenTextures[device] else { return false }
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
        CustomVideoCompositor.ciContext.render(
            scaled, to: screenTexture, commandBuffer: nil,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        )
        rig.screenMaterial.diffuse.contents = screenTexture
        return true
    }

    private func renderScene(_ rig: Rig, size: CGSize) -> CVPixelBuffer? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        if outputPool == nil || outputSize != (width, height) {
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary, &pool)
            outputPool = pool
            outputSize = (width, height)
            msaaTexture = nil
        }
        if msaaTexture == nil {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DMultisample
            descriptor.pixelFormat = .bgra8Unorm
            descriptor.width = width
            descriptor.height = height
            descriptor.sampleCount = 4
            descriptor.usage = .renderTarget
            descriptor.storageMode = .private
            msaaTexture = rig.device.makeTexture(descriptor: descriptor)
        }
        if textureCache == nil {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, rig.device, nil, &cache)
            textureCache = cache
        }
        guard let outputPool, let msaaTexture, let textureCache else { return nil }

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &buffer)
        guard let buffer else { return nil }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard let cvTexture, let resolve = CVMetalTextureGetTexture(cvTexture) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaaTexture
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve

        guard let commandBuffer = rig.commandQueue.makeCommandBuffer() else { return nil }
        rig.renderer.render(
            atTime: 0,
            viewport: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            commandBuffer: commandBuffer,
            passDescriptor: pass
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return withExtendedLifetime(cvTexture) { buffer }
    }

    private func loadRig(_ device: Device) -> Rig? {
        guard let url = BundledResource.url(device.resource),
              let scene = try? SCNScene(url: url, options: nil) else {
            Log.preview.error("MockupRenderer: \(device.resource) missing or unreadable")
            return nil
        }

        var screenMaterial: SCNMaterial?
        var screenAspect: CGFloat?
        Self.commit {
            scene.rootNode.enumerateHierarchy { node, _ in
                guard let geometry = node.geometry else { return }
                if geometry.materials.contains(where: { device.occludingMaterials.contains($0.name ?? "") }) {
                    node.isHidden = true
                    return
                }
                guard screenMaterial == nil,
                      geometry.materials.contains(where: { $0.name == device.screenMaterial }),
                      let projected = Self.screenGeometry(node) else { return }
                node.geometry = projected.geometry
                screenAspect = projected.aspect
                for material in projected.geometry.materials where material.name == device.screenMaterial {
                    material.lightingModel = .constant
                    material.diffuse.wrapS = .clamp
                    material.diffuse.wrapT = .clamp
                    material.emission.contents = NSColor.black
                    screenMaterial = material
                }
            }
        }
        guard let screenMaterial, let screenAspect else {
            Log.preview.error("MockupRenderer: \(device.screenMaterial) screen not found in \(device.resource)")
            return nil
        }

        let (boxMin, boxMax) = scene.rootNode.boundingBox
        let size = SCNVector3(boxMax.x - boxMin.x, boxMax.y - boxMin.y, boxMax.z - boxMin.z)
        let radius = Self.length(size) / 2
        guard radius > 0 else {
            Log.preview.error("MockupRenderer: \(device.resource) has no renderable geometry")
            return nil
        }
        let pivot = SCNNode()
        pivot.position = SCNVector3(
            (boxMin.x + boxMax.x) / 2, (boxMin.y + boxMax.y) / 2, (boxMin.z + boxMax.z) / 2
        )
        scene.rootNode.addChildNode(pivot)

        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 100_000
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        pivot.addChildNode(cameraNode)

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            Log.preview.error("MockupRenderer: Metal device unavailable")
            return nil
        }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true

        return Rig(
            renderer: renderer,
            screenMaterial: screenMaterial,
            pivot: pivot,
            cameraNode: cameraNode,
            camera: camera,
            radius: radius,
            screenAspect: screenAspect,
            device: device,
            commandQueue: commandQueue
        )
    }

    /// Replaces the authored UVs with a planar projection of the screen face, so the source image
    /// lands upright and edge-to-edge no matter how the model was unwrapped.
    private static func screenGeometry(_ node: SCNNode) -> (geometry: SCNGeometry, aspect: CGFloat)? {
        guard let geometry = node.geometry,
              let source = geometry.sources(for: .vertex).first,
              source.componentsPerVector >= 3,
              source.bytesPerComponent == MemoryLayout<Float>.size else { return nil }
        let stride = source.dataStride / MemoryLayout<Float>.size
        let offset = source.dataOffset / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: source.data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { source.data.copyBytes(to: $0) }

        let (bbMin, bbMax) = geometry.boundingBox
        let mins = [bbMin.x, bbMin.y, bbMin.z]
        let extents = [bbMax.x - bbMin.x, bbMax.y - bbMin.y, bbMax.z - bbMin.z]
        let plane = [0, 1, 2].sorted { extents[$0] > extents[$1] }.prefix(2)
        guard let first = plane.first, let second = plane.last, extents[second] > 0 else { return nil }

        let transform = node.worldTransform
        let firstDirection = Self.worldAxis(first, transform)
        let secondDirection = Self.worldAxis(second, transform)
        let horizontal = abs(firstDirection.x) >= abs(secondDirection.x)
        let uAxis = horizontal ? first : second
        let vAxis = horizontal ? second : first
        let uDirection = horizontal ? firstDirection : secondDirection
        let vDirection = horizontal ? secondDirection : firstDirection
        let flipU = uDirection.x < 0
        let flipV = vDirection.y > 0

        var uvs: [CGPoint] = []
        uvs.reserveCapacity(source.vectorCount)
        for i in 0..<source.vectorCount {
            let base = offset + i * stride
            let u = (CGFloat(floats[base + uAxis]) - mins[uAxis]) / extents[uAxis]
            let v = (CGFloat(floats[base + vAxis]) - mins[vAxis]) / extents[vAxis]
            uvs.append(CGPoint(x: flipU ? 1 - u : u, y: flipV ? 1 - v : v))
        }
        let projected = SCNGeometry(
            sources: geometry.sources.filter { $0.semantic != .texcoord } + [SCNGeometrySource(textureCoordinates: uvs)],
            elements: geometry.elements
        )
        projected.materials = geometry.materials

        let width = extents[uAxis] * Self.length(uDirection)
        let height = extents[vAxis] * Self.length(vDirection)
        guard width > 0, height > 0, (width / height).isFinite else { return nil }
        return (projected, min(max(width / height, 0.05), 20))
    }

    /// SceneKit defers scene mutations to its implicit transaction, which a headless renderer never
    /// flushes — without this the render lags one frame behind the pose and the uploaded screen.
    private static func commit(_ mutations: () -> Void) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        mutations()
        SCNTransaction.commit()
    }

    private static func worldAxis(_ index: Int, _ m: SCNMatrix4) -> SCNVector3 {
        switch index {
        case 0: SCNVector3(m.m11, m.m12, m.m13)
        case 1: SCNVector3(m.m21, m.m22, m.m23)
        default: SCNVector3(m.m31, m.m32, m.m33)
        }
    }

    private static func length(_ v: SCNVector3) -> CGFloat {
        CGFloat((v.x * v.x + v.y * v.y + v.z * v.z).squareRoot())
    }

    private static func centerCropped(_ image: CIImage, toAspect aspect: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let current = extent.width / extent.height
        var target = extent
        if current > aspect {
            target.size.width = extent.height * aspect
            target.origin.x += (extent.width - target.width) / 2
        } else {
            target.size.height = extent.width / aspect
            target.origin.y += (extent.height - target.height) / 2
        }
        return image.cropped(to: target)
    }

    private static func boundedRenderSize(_ size: CGSize) -> CGSize {
        let maxDimension: CGFloat = 2048
        let largest = max(size.width, size.height)
        guard largest > maxDimension, largest > 0 else { return size }
        let scale = maxDimension / largest
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
