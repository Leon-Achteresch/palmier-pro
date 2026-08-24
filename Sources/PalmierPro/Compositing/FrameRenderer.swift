import AVFoundation
import CoreImage

/// Composites a frame from a CompositorInstruction's layers with Core Image:
/// per-layer crop → effects → corner mask → transform → opacity, stacked bottom→top.
enum FrameRenderer {

    static func frameIndex(at compositionTime: CMTime, fps: Int) -> Int {
        guard fps > 0, compositionTime.isNumeric else { return 0 }
        let scaled = (compositionTime.seconds * Double(fps)).rounded()
        guard scaled.isFinite else { return 0 }
        return Int(min(max(scaled, Double(Int.min / 2)), Double(Int.max / 2)))
    }

    static func render(
        instruction: CompositorInstruction,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
        compositionTime: CMTime,
        into output: CVPixelBuffer,
        context: CIContext
    ) {
        let renderRect = CGRect(origin: .zero, size: instruction.renderSize)
        let frame = frameIndex(at: compositionTime, fps: instruction.fps)

        let base = CIImage(color: .black).cropped(to: renderRect)
        let accum = composite(
            layers: instruction.layers, over: base, frame: frame, fps: instruction.fps,
            renderSize: instruction.renderSize, sourceFrame: sourceFrame, gateByClipRange: false
        )
        let tagSource = colorTagSource(
            layers: instruction.layers,
            frame: frame,
            sourceFrame: sourceFrame,
            gateByClipRange: false
        )
        let outputColorSpace = tagSource.flatMap(colorSpace(for:)) ?? fallbackVideoColorSpace
        context.render(accum, to: output, bounds: renderRect, colorSpace: outputColorSpace)
        tagOutput(output, source: tagSource, colorSpace: outputColorSpace)
    }

    /// Bottom→top layer stack; `gateByClipRange` skips group children outside `frame`.
    private static func composite(
        layers: [LayerPlan],
        over background: CIImage,
        frame: Int,
        fps: Int,
        renderSize: CGSize,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
        gateByClipRange: Bool
    ) -> CIImage {
        var accum = background
        for layer in layers {
            if gateByClipRange, !layer.clip.contains(timelineFrame: frame) { continue }

            if case .adjustment = layer.source {
                accum = adjusted(accum, clip: layer.clip, frame: frame)
                continue
            }

            if case .text = layer.source, layer.clip.textFillMode == .footage {
                let opacity = min(1.0, max(0.0, layer.clip.opacityAt(frame: frame)))
                if opacity > 0, let mask = textStencilMask(layer, frame: frame, renderSize: renderSize) {
                    let original = accum
                    let color = (layer.clip.textStyle ?? TextStyle()).color
                    let matte = CIImage(color: CIColor(
                        red: CGFloat(color.r),
                        green: CGFloat(color.g),
                        blue: CGFloat(color.b),
                        alpha: CGFloat(color.a)
                    ))
                    .cropped(to: accum.extent)
                    .composited(over: accum)
                    let stencil = accum.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: matte,
                        kCIInputMaskImageKey: mask,
                    ]).cropped(to: accum.extent)
                    let stenciled = applyTextEffects(
                        stencil,
                        clip: layer.clip,
                        frame: frame,
                        renderSize: renderSize
                    )
                    if opacity < 1 {
                        let f = CIFilter(name: "CIDissolveTransition")
                        f?.setValue(original, forKey: kCIInputImageKey)
                        f?.setValue(stenciled, forKey: "inputTargetImage")
                        f?.setValue(opacity, forKey: "inputTime")
                        accum = (f?.outputImage ?? stenciled).cropped(to: original.extent)
                    } else {
                        accum = stenciled
                    }
                }
                continue
            }

            let mode: BlendMode
            if case .text = layer.source, layer.clip.textFillMode == .inverted {
                mode = .difference
            } else {
                mode = layer.clip.blendMode ?? .normal
            }
            // Source-over bakes opacity into alpha; blend modes apply it as a fade of
            // the blend RESULT (Photoshop/Premiere semantics), so don't bake it there.
            let isNormal = mode.ciFilterName == nil
            let image = layerImage(
                layer, frame: frame, fps: fps, renderSize: renderSize,
                sourceFrame: sourceFrame, bakeOpacity: isNormal
            )
            guard let image else { continue }
            if isNormal {
                if let occlusion = layer.clip.effects?.first(where: { $0.type == "key.occlusion" && $0.enabled }) {
                    accum = occludedComposite(image, over: accum, effect: occlusion,
                                              offset: frame - layer.clip.startFrame)
                } else if let reveal = layer.clip.effects?.first(where: { $0.type == "transition.subjectReveal" && $0.enabled }) {
                    accum = subjectRevealComposite(image, over: accum, effect: reveal,
                                                   offset: frame - layer.clip.startFrame)
                } else {
                    accum = image.composited(over: accum)
                }
            } else {
                let opacity = min(1.0, max(0.0, layer.clip.opacityAt(frame: frame)))
                accum = blend(image, over: accum, filter: mode.ciFilterName!, opacity: opacity)
            }
        }
        return accum
    }

    private static func adjusted(_ background: CIImage, clip: Clip, frame: Int) -> CIImage {
        let mix = min(1.0, max(0.0, clip.opacityAt(frame: frame)))
        let effects = clip.adjustmentEffects
        guard mix > 0, !effects.isEmpty else { return background }
        let extent = background.extent
        let offset = frame - clip.startFrame
        var image = background
        for effect in effects {
            guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
            image = descriptor.render(image, effect: effect, atOffset: offset)
        }
        image = image.cropped(to: extent)
        guard mix < 1 else { return image }
        let f = CIFilter(name: "CIDissolveTransition")
        f?.setValue(background, forKey: kCIInputImageKey)
        f?.setValue(image, forKey: "inputTargetImage")
        f?.setValue(mix, forKey: "inputTime")
        return (f?.outputImage ?? image).cropped(to: extent)
    }

    /// Composites `image`, then re-blends the subject of the frame below back on top,
    /// so the layer reads as sitting behind people in the scene. Passthrough composite
    /// when Vision finds no subject.
    private static func occludedComposite(
        _ image: CIImage,
        over accum: CIImage,
        effect: Effect,
        offset: Int
    ) -> CIImage {
        let composed = image.composited(over: accum)
        guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { return composed }
        let p = descriptor.resolve(effect, atOffset: offset)
        guard let matte = SubjectMask.matte(
            for: accum, extent: accum.extent,
            quality: p.value("quality"), feather: p.value("feather"),
            expand: p.value("expand"), invert: 0
        ) else { return composed }
        return accum.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: matte,
            kCIInputBackgroundImageKey: composed,
        ]).cropped(to: accum.extent)
    }

    private static func subjectRevealComposite(
        _ image: CIImage,
        over accum: CIImage,
        effect: Effect,
        offset: Int
    ) -> CIImage {
        let composed = image.composited(over: accum)
        guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { return composed }
        let p = descriptor.resolve(effect, atOffset: offset)
        let progress = p.value("progress")
        if progress <= 0 { return accum }
        if progress >= 1 { return composed }
        guard let matte = SubjectMask.revealMatte(
            for: accum, extent: accum.extent,
            quality: p.value("quality"), feather: p.value("feather"), progress: progress
        ) else {
            let f = CIFilter(name: "CIDissolveTransition")
            f?.setValue(accum, forKey: kCIInputImageKey)
            f?.setValue(composed, forKey: "inputTargetImage")
            f?.setValue(progress, forKey: "inputTime")
            return (f?.outputImage ?? composed).cropped(to: accum.extent)
        }
        return composed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: matte,
            kCIInputBackgroundImageKey: accum,
        ]).cropped(to: accum.extent)
    }

    private static func layerImage(
        _ layer: LayerPlan,
        frame: Int,
        fps: Int,
        renderSize: CGSize,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
        bakeOpacity: Bool
    ) -> CIImage? {
        switch layer.source {
        case .track(let id):
            guard let buffer = sourceFrame(id) else { return nil }
            return composedLayer(layer, buffer: buffer, frame: frame, fps: fps,
                                 renderSize: renderSize, bakeOpacity: bakeOpacity)
        case .text:
            return composedTextLayer(layer, frame: frame, renderSize: renderSize,
                                     bakeOpacity: bakeOpacity)
        case .adjustment:
            return nil
        case .group(let children, let canvas):
            return composedGroupLayer(layer, children: children, canvas: canvas, frame: frame, fps: fps,
                                      renderSize: renderSize, sourceFrame: sourceFrame, bakeOpacity: bakeOpacity)
        case .transition(let from, let to, let plan):
            return composedTransitionLayer(from: from, to: to, plan: plan, frame: frame, fps: fps,
                                           renderSize: renderSize, sourceFrame: sourceFrame)
        }
    }

    private static func composedTransitionLayer(
        from: LayerPlan,
        to: LayerPlan,
        plan: TransitionPlan,
        frame: Int,
        fps: Int,
        renderSize: CGSize,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?
    ) -> CIImage? {
        let fromImage = layerImage(from, frame: frame, fps: fps, renderSize: renderSize,
                                   sourceFrame: sourceFrame, bakeOpacity: true)
        let toImage = layerImage(to, frame: frame, fps: fps, renderSize: renderSize,
                                 sourceFrame: sourceFrame, bakeOpacity: true)
        return TransitionCompositor.blend(
            from: fromImage,
            to: toImage,
            style: plan.style,
            direction: plan.direction,
            progress: plan.window.progress(at: frame),
            renderRect: CGRect(origin: .zero, size: renderSize)
        )
    }

    private static func textStencilMask(
        _ layer: LayerPlan,
        frame: Int,
        renderSize: CGSize
    ) -> CIImage? {
        var clip = layer.clip
        var style = clip.textStyle ?? TextStyle()
        style.color = .init(r: 1, g: 1, b: 1, a: 1)
        clip.textStyle = style
        guard let image = TextFrameRenderer.image(clip: clip, frame: frame, renderSize: renderSize) else {
            return nil
        }
        return transformedTextImage(image, clip: clip, frame: frame, renderSize: renderSize)
    }

    /// Children composite at the child canvas; the nest clip's pipeline runs on the result.
    private static func composedGroupLayer(
        _ layer: LayerPlan,
        children: [LayerPlan],
        canvas: CGSize,
        frame: Int,
        fps: Int,
        renderSize: CGSize,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
        bakeOpacity: Bool
    ) -> CIImage? {
        let alpha = min(1.0, max(0.0, layer.clip.opacityAt(frame: frame)))
        guard alpha > 0, canvas.width > 0, canvas.height > 0 else { return nil }
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let base = CIImage(color: .black).cropped(to: canvasRect)
        let intermediate = composite(
            layers: children, over: base, frame: frame, fps: fps,
            renderSize: canvas, sourceFrame: sourceFrame, gateByClipRange: true
        )
        return applyClipPipeline(
            image: intermediate, srcHeight: canvas.height, layer: layer, frame: frame, fps: fps,
            renderSize: renderSize, alpha: alpha, bakeOpacity: bakeOpacity
        )
    }

    /// Blend `image` over `background`, then fade the blend to background by `opacity`.
    private static func blend(_ image: CIImage, over background: CIImage, filter name: String, opacity: Double) -> CIImage {
        // Ensure blend covers entire frame; avoid black borders.
        let blended = image.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: background])
            .composited(over: background)
        guard opacity < 1 else { return blended }
        let f = CIFilter(name: "CIDissolveTransition")
        f?.setValue(background, forKey: kCIInputImageKey)
        f?.setValue(blended, forKey: "inputTargetImage")
        f?.setValue(opacity, forKey: "inputTime")
        return (f?.outputImage ?? blended).cropped(to: background.extent)
    }

    private static func tagOutput(
        _ output: CVPixelBuffer,
        source: CVPixelBuffer?,
        colorSpace: CGColorSpace
    ) {
        if let source {
            copyColorTags(from: source, to: output)
        } else {
            tag709(output)
        }
        CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
    }

    private static func colorTagSource(
        layers: [LayerPlan],
        frame: Int,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
        gateByClipRange: Bool
    ) -> CVPixelBuffer? {
        for layer in layers.reversed() {
            if gateByClipRange, !layer.clip.contains(timelineFrame: frame) { continue }
            guard layer.clip.opacityAt(frame: frame) > 0 else { continue }
            switch layer.source {
            case .track(let id):
                if let buffer = sourceFrame(id) { return buffer }
            case .text, .adjustment:
                continue
            case .group(let children, _):
                if let buffer = colorTagSource(
                    layers: children,
                    frame: frame,
                    sourceFrame: sourceFrame,
                    gateByClipRange: true
                ) {
                    return buffer
                }
            case .transition(let from, let to, _):
                if let buffer = colorTagSource(
                    layers: [from, to],
                    frame: frame,
                    sourceFrame: sourceFrame,
                    gateByClipRange: false
                ) {
                    return buffer
                }
            }
        }
        return nil
    }

    private static func copyColorTags(from source: CVPixelBuffer, to output: CVPixelBuffer) {
        let keys: [CFString] = [
            kCVImageBufferICCProfileKey,
            kCVImageBufferCGColorSpaceKey,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferGammaLevelKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            kCVImageBufferContentLightLevelInfoKey,
        ]
        for key in keys {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(output, key, value, .shouldPropagate)
            } else {
                CVBufferRemoveAttachment(output, key)
            }
        }
    }

    private static let fallbackVideoColorSpace =
        CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    private static func colorSpace(for buffer: CVPixelBuffer) -> CGColorSpace? {
        if let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate),
           let unmanaged = CVImageBufferCreateColorSpaceFromAttachments(attachments) {
            return unmanaged.takeRetainedValue()
        }
        guard let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil) else {
            return nil
        }
        return (attachment as! CGColorSpace)
    }

    private static func tag709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private static func composedLayer(
        _ layer: LayerPlan,
        buffer: CVPixelBuffer,
        frame: Int,
        fps: Int,
        renderSize: CGSize,
        bakeOpacity: Bool = true
    ) -> CIImage? {
        let alpha = min(1.0, max(0.0, layer.clip.opacityAt(frame: frame)))
        guard alpha > 0 else { return nil }

        // Undo premultiplied alpha to avoid dark edges.
        let image = CIImage(
            cvPixelBuffer: buffer,
            options: [.colorSpace: colorSpace(for: buffer) ?? fallbackVideoColorSpace]
        )
            .unpremultiplyingAlpha()
        return applyClipPipeline(
            image: image, srcHeight: CGFloat(CVPixelBufferGetHeight(buffer)), layer: layer,
            frame: frame, fps: fps, renderSize: renderSize, alpha: alpha, bakeOpacity: bakeOpacity
        )
    }

    /// Crop → effects → corner mask → transform → opacity, sampled from `layer.clip` at `frame`.
    private static func applyClipPipeline(
        image input: CIImage,
        srcHeight: CGFloat,
        layer: LayerPlan,
        frame: Int,
        fps: Int,
        renderSize: CGSize,
        alpha: Double,
        bakeOpacity: Bool
    ) -> CIImage? {
        let clip = layer.clip
        var image = input

        let crop = clip.cropAt(frame: frame)
        if !crop.isIdentity {
            // Display-space insets → source pixels → CI's bottom-left origin.
            let avRect = CGRect(
                x: crop.left * layer.natSize.width,
                y: crop.top * layer.natSize.height,
                width: max(1, crop.visibleWidthFraction * layer.natSize.width),
                height: max(1, crop.visibleHeightFraction * layer.natSize.height)
            ).applying(layer.preferredTransform.inverted())
            image = image.cropped(to: CGRect(
                x: avRect.origin.x,
                y: srcHeight - avRect.origin.y - avRect.height,
                width: avRect.width,
                height: avRect.height
            ))
        }

        // Effects apply in source-pixel space: after crop, before placement.
        if let effects = clip.effects, !effects.isEmpty {
            let offset = frame - clip.startFrame
            for effect in effects where effect.enabled {
                guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
                image = descriptor.render(image, effect: effect, atOffset: offset)
            }
        }

        if let sample = clip.stabilizationSample(atTimelineFrame: frame, fps: fps),
           let stabilization = clip.stabilization {
            image = stabilized(image, sample: sample, cropScale: stabilization.cropScale)
        }

        image = EdgeRoundingKernel.apply(
            image,
            edgeRounding: clip.edgeRounding,
            edgeSoftness: clip.edgeSoftness
        )

        if let quad = clip.cornerPinQuad(at: frame) {
            // Source rotation metadata still applies; the pin then places the upright frame.
            image = uprightedSource(image, layer: layer, srcHeight: srcHeight)
            guard let pinned = cornerPinned(image, quad: quad, renderSize: renderSize) else { return nil }
            image = pinned
        } else if let grid = clip.meshWarpGrid(at: frame) {
            image = uprightedSource(image, layer: layer, srcHeight: srcHeight)
            guard let warped = MeshWarpKernel.place(image, grid: grid, renderSize: renderSize) else { return nil }
            image = warped
        } else {
            let t = clip.transformAt(frame: frame)
            let av = layer.preferredTransform.concatenating(
                CompositionBuilder.affineTransform(for: t, natSize: layer.natSize, renderSize: renderSize)
            )
            // Conjugate the AV top-left-origin mapping into CI's bottom-left space.
            let ci = flipY(srcHeight).concatenating(av).concatenating(flipY(renderSize.height))
            image = image.transformed(by: ci)
        }
        image = image.premultiplyingAlpha()

        if bakeOpacity, alpha < 1 {
            // Fade alpha only; scaling RGB would double-fade
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        return image
    }

    static func stabilized(_ image: CIImage, sample: StabilizationSample, cropScale: Double) -> CIImage {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite, !extent.isNull,
              cropScale.isFinite, cropScale >= 1 else { return image }
        let center = CGPoint(x: extent.midX, y: extent.midY)
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: cropScale, y: cropScale)
            .rotated(by: sample.rotation)
            .translatedBy(x: -center.x, y: -center.y)
        transform = transform.concatenating(CGAffineTransform(
            translationX: sample.dx * extent.width,
            y: sample.dy * extent.height
        ))
        return image.transformed(by: transform).cropped(to: extent)
    }

    private static func uprightedSource(_ image: CIImage, layer: LayerPlan, srcHeight: CGFloat) -> CIImage {
        guard !layer.preferredTransform.isIdentity else { return image }
        return image.transformed(by: flipY(srcHeight)
            .concatenating(layer.preferredTransform)
            .concatenating(flipY(layer.natSize.height)))
    }

    /// Warps the layer onto its pin quad in canvas space, replacing the affine placement.
    /// Nil when the quad collapsed — nothing visible to composite.
    private static func cornerPinned(
        _ image: CIImage,
        quad: CornerPin.Quad,
        renderSize: CGSize
    ) -> CIImage? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite, !extent.isNull,
              quad.isRenderable(in: renderSize) else { return nil }
        // Canvas coords are top-left origin; CI's are bottom-left.
        func vector(_ p: CGPoint) -> CIVector {
            CIVector(x: p.x * renderSize.width, y: (1 - p.y) * renderSize.height)
        }
        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": vector(quad.topLeft),
            "inputTopRight": vector(quad.topRight),
            "inputBottomRight": vector(quad.bottomRight),
            "inputBottomLeft": vector(quad.bottomLeft),
        ])
    }

    /// Text renders in place; effects run before rotation and opacity, matching visual clips.
    private static func composedTextLayer(
        _ layer: LayerPlan,
        frame: Int,
        renderSize: CGSize,
        bakeOpacity: Bool = true
    ) -> CIImage? {
        var clip = layer.clip
        let alpha = min(1.0, max(0.0, clip.opacityAt(frame: frame)))
        guard alpha > 0 else { return nil }
        if clip.textFillMode == .inverted {
            var style = clip.textStyle ?? TextStyle()
            style.color = .init(r: 1, g: 1, b: 1, a: 1)
            style.border.enabled = false
            style.shadow.enabled = false
            style.background.color.a = 0
            style.background.outlineColor.a = 0
            clip.textStyle = style
        }
        guard var image = TextFrameRenderer.image(clip: clip, frame: frame, renderSize: renderSize)?
            .unpremultiplyingAlpha() else { return nil }

        image = applyTextEffects(image, clip: clip, frame: frame, renderSize: renderSize)
        if clip.textFillMode == .inverted {
            let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": zero,
                "inputGVector": zero,
                "inputBVector": zero,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ])
        }
        if let quad = clip.cornerPinQuad(at: frame) {
            guard let pinned = cornerPinned(image, quad: quad, renderSize: renderSize) else { return nil }
            image = pinned
        } else if let grid = clip.meshWarpGrid(at: frame) {
            guard let warped = MeshWarpKernel.place(image, grid: grid, renderSize: renderSize) else { return nil }
            image = warped
        } else {
            image = transformedTextImage(image, clip: clip, frame: frame, renderSize: renderSize)
        }
        image = image.premultiplyingAlpha()

        if bakeOpacity, alpha < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        return image
    }

    static func applyTextEffects(
        _ input: CIImage,
        clip: Clip,
        frame: Int,
        renderSize: CGSize
    ) -> CIImage {
        let blurRadius = clip.blurRadius(at: frame)
        let effects = (clip.effects ?? []).filter { $0.type != Effect.gaussianBlurType }
        guard blurRadius > 0 || !effects.isEmpty else { return input }
        let renderRect = CGRect(origin: .zero, size: renderSize)
        var image = input.composited(over: CIImage(color: .clear).cropped(to: renderRect))
        let offset = frame - clip.startFrame
        let spatialScale = Double(renderSize.height / TextLayout.referenceCanvasHeight)
        if blurRadius.isFinite,
           let descriptor = EffectRegistry.descriptor(id: Effect.gaussianBlurType) {
            image = descriptor.render(
                image,
                effect: Effect.make(
                    Effect.gaussianBlurType,
                    [Effect.gaussianBlurRadiusKey: blurRadius]
                ),
                atOffset: offset,
                spatialScale: spatialScale
            )
        }
        for effect in effects where effect.enabled {
            guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
            image = descriptor.render(
                image,
                effect: effect,
                atOffset: offset,
                spatialScale: spatialScale
            )
        }
        return image
    }

    private static func transformedTextImage(
        _ image: CIImage,
        clip: Clip,
        frame: Int,
        renderSize: CGSize
    ) -> CIImage {
        let transform = clip.transformAt(frame: frame)
        if transform.hasTiltRotation {
            return tiltedTextImage(image, transform: transform, renderSize: renderSize)
        }

        let rotation = CompositionBuilder.canvasRotationTransform(for: transform, renderSize: renderSize)
        guard !rotation.isIdentity else { return image }
        let ciTransform = flipY(renderSize.height)
            .concatenating(rotation)
            .concatenating(flipY(renderSize.height))
        return image.transformed(by: ciTransform)
    }

    /// Projects the raster's actual extent, so glyphs drawn off canvas can tilt back into frame.
    private static func tiltedTextImage(
        _ image: CIImage,
        transform: Transform,
        renderSize: CGSize
    ) -> CIImage {
        let source = image.extent.isInfinite
            ? image.cropped(to: CGRect(origin: .zero, size: renderSize))
            : image
        guard !source.extent.isEmpty else { return image }

        let flip = flipY(renderSize.height)
        let corners = TextTiltGeometry.corners(
            of: source.extent.applying(flip),
            around: CGPoint(
                x: transform.centerX * renderSize.width,
                y: transform.centerY * renderSize.height
            ),
            transform: transform,
            canvasSize: renderSize
        )
        return source.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: corners.topLeft.applying(flip)),
            "inputTopRight": CIVector(cgPoint: corners.topRight.applying(flip)),
            "inputBottomRight": CIVector(cgPoint: corners.bottomRight.applying(flip)),
            "inputBottomLeft": CIVector(cgPoint: corners.bottomLeft.applying(flip)),
        ])
    }

    private static func flipY(_ height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }
}
