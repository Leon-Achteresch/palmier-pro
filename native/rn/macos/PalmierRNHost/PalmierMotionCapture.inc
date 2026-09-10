#import <Metal/Metal.h>
#import <QuartzCore/CARenderer.h>

static BOOL motionLeafImages(NSView *view, CALayer *root, NSMapTable<CALayer *, id> *images, NSUInteger *remainingPixels) {
  if (view.hidden) return YES;
  CGSize size = view.bounds.size;
  if (view.subviews.count == 0 && size.width > 0 && size.height > 0 && view.layer) {
    CGPoint origin = [view.layer convertPoint:CGPointZero toLayer:root];
    CGPoint x = [view.layer convertPoint:CGPointMake(1, 0) toLayer:root];
    CGPoint y = [view.layer convertPoint:CGPointMake(0, 1) toLayer:root];
    double width = ceil(size.width * hypot(x.x - origin.x, x.y - origin.y));
    double height = ceil(size.height * hypot(y.x - origin.x, y.y - origin.y));
    if (!isfinite(width) || !isfinite(height)) return NO;
    NSUInteger pixelsWide = (NSUInteger)fmax(1, fmin(4096, width));
    NSUInteger pixelsHigh = (NSUInteger)fmax(1, fmin(4096, height));
    NSUInteger count = pixelsWide * pixelsHigh;
    if (count > *remainingPixels) return NO;
    *remainingPixels -= count;
    @autoreleasepool {
      NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pixelsWide pixelsHigh:pixelsHigh
          bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
      if (!bitmap) return NO;
      bitmap.size = size;
      [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
      if (!bitmap.CGImage) return NO;
      [images setObject:(__bridge id)bitmap.CGImage forKey:view.layer];
    }
  }
  for (NSView *child in view.subviews) if (!motionLeafImages(child, root, images, remainingPixels)) return NO;
  return YES;
}

static void restoreMotionMasks(NSView *view) {
  if ([view isKindOfClass:PalmierMotionMaskView.class]) [(PalmierMotionMaskView *)view updateMotionMask];
  for (NSView *child in view.subviews) restoreMotionMasks(child);
}

// AppKit backing layers need independent contents in a separate render context.
static CALayer *motionLayerSnapshot(CALayer *source, NSMapTable<CALayer *, id> *images) {
  Class type = [source isKindOfClass:CAShapeLayer.class] ? CAShapeLayer.class :
      [source isKindOfClass:CAGradientLayer.class] ? CAGradientLayer.class :
      [source isKindOfClass:CATextLayer.class] ? CATextLayer.class : CALayer.class;
  CALayer *copy = [type layer];
  copy.delegate = nil;
  copy.bounds = source.bounds;
  copy.position = source.position;
  copy.anchorPoint = source.anchorPoint;
  copy.transform = source.transform;
  copy.sublayerTransform = source.sublayerTransform;
  copy.geometryFlipped = source.geometryFlipped;
  copy.opacity = source.opacity;
  copy.hidden = source.hidden;
  copy.contentsScale = source.contentsScale;
  copy.minificationFilter = source.minificationFilter;
  copy.magnificationFilter = source.magnificationFilter;
  copy.allowsEdgeAntialiasing = source.allowsEdgeAntialiasing;
  copy.edgeAntialiasingMask = source.edgeAntialiasingMask;
  copy.compositingFilter = source.compositingFilter;
  copy.backgroundFilters = source.backgroundFilters;
  copy.contents = [images objectForKey:source] ?: source.contents;
  copy.contentsRect = source.contentsRect;
  copy.contentsCenter = source.contentsCenter;
  copy.contentsGravity = source.contentsGravity;
  copy.borderColor = source.borderColor;
  copy.borderWidth = source.borderWidth;
  copy.shadowColor = source.shadowColor;
  copy.shadowOpacity = source.shadowOpacity;
  copy.shadowOffset = source.shadowOffset;
  copy.shadowRadius = source.shadowRadius;
  copy.shadowPath = source.shadowPath;
  if ([source isKindOfClass:CAShapeLayer.class]) {
    CAShapeLayer *shape = (CAShapeLayer *)source, *target = (CAShapeLayer *)copy;
    target.path = shape.path;
    target.fillColor = shape.fillColor;
    target.fillRule = shape.fillRule;
    target.strokeColor = shape.strokeColor;
    target.lineWidth = shape.lineWidth;
    target.lineCap = shape.lineCap;
    target.lineJoin = shape.lineJoin;
    target.miterLimit = shape.miterLimit;
    target.lineDashPattern = shape.lineDashPattern;
    target.lineDashPhase = shape.lineDashPhase;
    target.strokeStart = shape.strokeStart;
    target.strokeEnd = shape.strokeEnd;
  }
  if ([source isKindOfClass:CAGradientLayer.class]) {
    CAGradientLayer *gradient = (CAGradientLayer *)source, *target = (CAGradientLayer *)copy;
    target.colors = gradient.colors;
    target.locations = gradient.locations;
    target.startPoint = gradient.startPoint;
    target.endPoint = gradient.endPoint;
    target.type = gradient.type;
  }
  if ([source isKindOfClass:CATextLayer.class]) {
    CATextLayer *text = (CATextLayer *)source, *target = (CATextLayer *)copy;
    target.string = text.string;
    target.font = text.font;
    target.fontSize = text.fontSize;
    target.foregroundColor = text.foregroundColor;
    target.wrapped = text.wrapped;
    target.alignmentMode = text.alignmentMode;
    target.truncationMode = text.truncationMode;
  }
  copy.backgroundColor = source.backgroundColor;
  copy.cornerRadius = source.cornerRadius;
  copy.masksToBounds = source.masksToBounds;
  copy.filters = source.filters;
  copy.mask = source.mask ? motionLayerSnapshot(source.mask, images) : nil;
  NSMutableArray<CALayer *> *children = [NSMutableArray array];
  if (![images objectForKey:source]) {
    for (CALayer *child in source.sublayers) [children addObject:motionLayerSnapshot(child, images)];
  }
  copy.sublayers = children;
  return copy;
}

@interface PalmierMotionCapture : NSObject
- (void)captureView:(NSView *)view size:(CGSize)size completion:(void (^)(CGImageRef, NSError *))completion;
@end

@implementation PalmierMotionCapture {
  id<MTLCommandQueue> _queue;
  id<MTLTexture> _texture;
  CARenderer *_renderer;
  MTLRenderPassDescriptor *_clearPass;
  BOOL _capturing;
}

static NSError *motionCaptureError(NSString *message) {
  return [NSError errorWithDomain:@"PalmierRNHost" code:4 userInfo:@{NSLocalizedDescriptionKey:message}];
}

- (void)captureView:(NSView *)view size:(CGSize)size completion:(void (^)(CGImageRef, NSError *))completion {
  if (_capturing) { completion(NULL, motionCaptureError(@"A native frame capture is already running")); return; }
  if (!isfinite(size.width) || !isfinite(size.height) || size.width < 1 || size.height < 1 || size.width > 4096 || size.height > 4096) {
    completion(NULL, motionCaptureError(@"Invalid native frame dimensions")); return;
  }
  _capturing = YES;
  if (_renderer) { [self renderView:view size:size completion:completion]; return; }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:(NSUInteger)size.width height:(NSUInteger)size.height mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CARenderer *renderer = texture && queue ? [CARenderer rendererWithMTLTexture:texture options:@{kCARendererMetalCommandQueue:queue, kCARendererColorSpace:(__bridge id)colorSpace}] : nil;
    CGColorSpaceRelease(colorSpace);
    MTLRenderPassDescriptor *clearPass = [MTLRenderPassDescriptor renderPassDescriptor];
    clearPass.colorAttachments[0].texture = texture;
    clearPass.colorAttachments[0].loadAction = MTLLoadActionClear;
    clearPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    clearPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!queue || !texture || !renderer) { self->_capturing = NO; completion(NULL, motionCaptureError(@"Could not create the native frame render target")); return; }
      self->_queue = queue;
      self->_texture = texture;
      self->_renderer = renderer;
      self->_clearPass = clearPass;
      [self renderView:view size:size completion:completion];
    });
  });
}

- (void)renderView:(NSView *)view size:(CGSize)size completion:(void (^)(CGImageRef, NSError *))completion {
  [view displayIfNeeded];
  NSMapTable *images = [NSMapTable strongToStrongObjectsMapTable];
  NSUInteger remainingPixels = 32 * 1024 * 1024;
  if (!motionLeafImages(view, view.layer, images, &remainingPixels)) {
    _capturing = NO;
    completion(NULL, motionCaptureError(@"Native frame capture exceeded its image budget or could not capture a view"));
    return;
  }
  restoreMotionMasks(view);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _renderer.layer = motionLayerSnapshot(view.layer, images);
  _renderer.bounds = CGRectMake(0, 0, size.width, size.height);
  _renderer.layer.bounds = _renderer.bounds;
  _renderer.layer.position = CGPointZero;
  _renderer.layer.anchorPoint = CGPointZero;


  [CATransaction commit];
  [CATransaction flush];
  id<MTLCommandBuffer> clear = [_queue commandBuffer];
  id<MTLRenderCommandEncoder> clearEncoder = [clear renderCommandEncoderWithDescriptor:_clearPass];
  if (!clearEncoder) {
    _capturing = NO;
    _renderer.layer = nil;
    completion(NULL, motionCaptureError(@"Could not clear the native frame render target"));
    return;
  }
  [clearEncoder endEncoding];
  [clear commit];
  [_renderer beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
  [_renderer addUpdateRect:_renderer.bounds];
  [_renderer render];
  [_renderer endFrame];
  id<MTLTexture> texture = _texture;
  id<MTLCommandBuffer> barrier = [_queue commandBuffer];
  if (!barrier) {
    _capturing = NO;
    _renderer.layer = nil;
    completion(NULL, motionCaptureError(@"Could not submit the native frame capture"));
    return;
  }
  [barrier addCompletedHandler:^(id<MTLCommandBuffer> command) {
    NSError *error = command.error;
    CGImageRef image = NULL;
    if (!error) {
      NSUInteger rowBytes = texture.width * 4;
      NSMutableData *pixels = [NSMutableData dataWithLength:rowBytes * texture.height];
      [texture getBytes:pixels.mutableBytes bytesPerRow:rowBytes fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height) mipmapLevel:0];
      NSMutableData *row = [NSMutableData dataWithLength:rowBytes];
      uint8_t *bytes = (uint8_t *)pixels.mutableBytes;
      for (NSUInteger y = 0; y < texture.height / 2; y++) {
        uint8_t *top = bytes + y * rowBytes, *bottom = bytes + (texture.height - 1 - y) * rowBytes;
        memcpy(row.mutableBytes, top, rowBytes);
        memcpy(top, bottom, rowBytes);
        memcpy(bottom, row.bytes, rowBytes);
      }
      CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
      CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      image = CGImageCreate(texture.width, texture.height, 8, 32, rowBytes, colorSpace,
          (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, provider, NULL, NO, kCGRenderingIntentDefault);
      CGColorSpaceRelease(colorSpace);
      CGDataProviderRelease(provider);
      if (!image) error = motionCaptureError(@"Could not read the native rendered frame");
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_capturing = NO;
      self->_renderer.layer = nil;
      completion(image, error);
      if (image) CGImageRelease(image);
    });
  }];
  [barrier commit];
}
@end
