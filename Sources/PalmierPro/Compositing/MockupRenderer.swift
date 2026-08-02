import AppKit
import CoreImage
import SceneKit

final class MockupRenderer: @unchecked Sendable {
    static let shared = MockupRenderer()

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
    private var rig: Rig??
    private var screenTexture: MTLTexture?
    private var msaaTexture: MTLTexture?
    private var outputPool: CVPixelBufferPool?
    private var outputSize: (width: Int, height: Int) = (0, 0)
    private var textureCache: CVMetalTextureCache?

    func render(screen: CIImage, pose: CameraPose, extent: CGRect) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        if rig == nil { rig = loadRig() }
        guard let rig = rig ?? nil else { return nil }

        let cropped = Self.centerCropped(screen, toAspect: rig.screenAspect)
        guard uploadScreen(cropped, rig: rig) else { return nil }

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

    private func uploadScreen(_ image: CIImage, rig: Rig) -> Bool {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return false }
        let scale = min(1, 2048 / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        if screenTexture.map({ $0.width != width || $0.height != height }) ?? true {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            screenTexture = rig.device.makeTexture(descriptor: descriptor)
        }
        guard let screenTexture else { return false }
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

    private func loadRig() -> Rig? {
        guard let url = BundledResource.url("Mockups/iPhone17Pro.usdz"),
              let scene = try? SCNScene(url: url, options: nil) else {
            Log.preview.error("MockupRenderer: iPhone17Pro.usdz missing or unreadable")
            return nil
        }

        var screenMaterial: SCNMaterial?
        var screenExtents: SCNVector3 = SCNVector3Zero
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  geometry.materials.contains(where: { $0.name == "Screen_BG" }) else { return }
            let remapped = Self.screenGeometry(geometry)
            node.geometry = remapped
            for material in remapped.materials where material.name == "Screen_BG" {
                material.lightingModel = .constant
                material.diffuse.wrapS = .clamp
                material.diffuse.wrapT = .clamp
                material.emission.contents = NSColor.black
                screenMaterial = material
            }
            let (bbMin, bbMax) = remapped.boundingBox
            screenExtents = SCNVector3(bbMax.x - bbMin.x, bbMax.y - bbMin.y, bbMax.z - bbMin.z)
        }
        guard let screenMaterial else {
            Log.preview.error("MockupRenderer: Screen_BG material not found in iPhone17Pro.usdz")
            return nil
        }

        let dims = [screenExtents.x, screenExtents.y, screenExtents.z].sorted(by: >)
        let screenAspect = dims[0] > 0 ? max(dims[1] / dims[0], 0.1) : 0.46

        let sphere = scene.rootNode.boundingSphere
        let pivot = SCNNode()
        pivot.position = sphere.center
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
            radius: CGFloat(sphere.radius),
            screenAspect: screenAspect,
            device: device,
            commandQueue: commandQueue
        )
    }

    private static func screenGeometry(_ geometry: SCNGeometry) -> SCNGeometry {
        guard let source = geometry.sources(for: .texcoord).first,
              source.componentsPerVector >= 2,
              source.bytesPerComponent == MemoryLayout<Float>.size else { return geometry }
        let stride = source.dataStride / MemoryLayout<Float>.size
        let offset = source.dataOffset / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: source.data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { source.data.copyBytes(to: $0) }

        var minU: Float = .greatestFiniteMagnitude, maxU: Float = -.greatestFiniteMagnitude
        var minV: Float = .greatestFiniteMagnitude, maxV: Float = -.greatestFiniteMagnitude
        for i in 0..<source.vectorCount {
            let base = offset + i * stride
            minU = min(minU, floats[base]); maxU = max(maxU, floats[base])
            minV = min(minV, floats[base + 1]); maxV = max(maxV, floats[base + 1])
        }
        let du = maxU - minU, dv = maxV - minV
        guard du > 0, dv > 0 else { return geometry }

        var uvs: [CGPoint] = []
        uvs.reserveCapacity(source.vectorCount)
        for i in 0..<source.vectorCount {
            let base = offset + i * stride
            let nu = (floats[base] - minU) / du
            let nv = (floats[base + 1] - minV) / dv
            uvs.append(CGPoint(x: CGFloat(1 - nv), y: CGFloat(1 - nu)))
        }
        let remapped = SCNGeometry(
            sources: geometry.sources.filter { $0.semantic != .texcoord } + [SCNGeometrySource(textureCoordinates: uvs)],
            elements: geometry.elements
        )
        remapped.materials = geometry.materials
        return remapped
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
