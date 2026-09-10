#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <React/RCTView.h>

// Prepared off-main before a native surface loads; only copies are modified.
static CIFilter *motionBlurTemplate;

static BOOL prepareMotionFilters(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{ motionBlurTemplate = [CIFilter filterWithName:@"CIGaussianBlur"]; });
  return motionBlurTemplate != nil;
}

static CGColorRef motionColor(NSString *value) {
  NSString *hex = [value hasPrefix:@"#"] ? [value substringFromIndex:1] : @"";
  if (hex.length == 3 || hex.length == 4) {
    NSMutableString *expanded = [NSMutableString string];
    for (NSUInteger i = 0; i < hex.length; i++) [expanded appendFormat:@"%C%C", [hex characterAtIndex:i], [hex characterAtIndex:i]];
    hex = expanded;
  }
  if (hex.length != 6 && hex.length != 8) return NSColor.clearColor.CGColor;
  unsigned long long bits = 0;
  if (![[NSScanner scannerWithString:hex] scanHexLongLong:&bits]) return NSColor.clearColor.CGColor;
  if (hex.length == 6) bits = (bits << 8) | 255;
  return [NSColor colorWithSRGBRed:((bits >> 24) & 255) / 255.0 green:((bits >> 16) & 255) / 255.0 blue:((bits >> 8) & 255) / 255.0 alpha:(bits & 255) / 255.0].CGColor;
}

@interface PalmierMotionShapeView : RCTView
@property (nonatomic, copy) NSArray<NSDictionary *> *commands;
@property (nonatomic, copy) NSString *motionFill;
@property (nonatomic, copy) NSString *motionStroke;
@property (nonatomic) CGFloat motionStrokeWidth;
@property (nonatomic) CGFloat motionProgress;
@end

@implementation PalmierMotionShapeView {
  CAShapeLayer *_shape;
}
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES;
    _shape = [CAShapeLayer layer];
    _shape.actions = @{@"path": NSNull.null, @"fillColor": NSNull.null, @"strokeColor": NSNull.null, @"strokeEnd": NSNull.null, @"lineWidth": NSNull.null};
    [self.layer addSublayer:_shape];
  }
  return self;
}
- (void)setCommands:(NSArray<NSDictionary *> *)commands {
  if ([_commands isEqual:commands]) return;
  _commands = [commands copy];
  CGMutablePathRef path = CGPathCreateMutable();
  for (NSDictionary *command in commands) {
    NSString *type = command[@"type"];
    if ([type isEqual:@"M"]) CGPathMoveToPoint(path, NULL, [command[@"x"] doubleValue], [command[@"y"] doubleValue]);
    else if ([type isEqual:@"L"]) CGPathAddLineToPoint(path, NULL, [command[@"x"] doubleValue], [command[@"y"] doubleValue]);
    else if ([type isEqual:@"C"]) CGPathAddCurveToPoint(path, NULL, [command[@"cp1x"] doubleValue], [command[@"cp1y"] doubleValue], [command[@"cp2x"] doubleValue], [command[@"cp2y"] doubleValue], [command[@"x"] doubleValue], [command[@"y"] doubleValue]);
    else if ([type isEqual:@"Z"]) CGPathCloseSubpath(path);
  }
  _shape.path = path;
  CGPathRelease(path);
}
- (void)setMotionFill:(NSString *)value { _motionFill = [value copy]; _shape.fillColor = motionColor(value); }
- (void)setMotionStroke:(NSString *)value { _motionStroke = [value copy]; _shape.strokeColor = motionColor(value); }
- (void)setMotionStrokeWidth:(CGFloat)value { _motionStrokeWidth = value; _shape.lineWidth = value; }
- (void)setMotionProgress:(CGFloat)value { _motionProgress = value; _shape.strokeEnd = value; }
- (void)layout { [super layout]; _shape.frame = self.bounds; }
@end

@interface PalmierMotionShapeManager : RCTViewManager
@end
@implementation PalmierMotionShapeManager
RCT_EXPORT_MODULE(PalmierMotionShape)
RCT_EXPORT_VIEW_PROPERTY(commands, NSArray)
RCT_EXPORT_VIEW_PROPERTY(motionFill, NSString)
RCT_EXPORT_VIEW_PROPERTY(motionStroke, NSString)
RCT_EXPORT_VIEW_PROPERTY(motionStrokeWidth, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(motionProgress, CGFloat)
- (NSView *)view { return [PalmierMotionShapeView new]; }
@end

@interface PalmierMotionMaskView : RCTView
@property (nonatomic, copy) NSString *motionMask;
@property (nonatomic) CGFloat motionReveal;
@property (nonatomic) CGFloat motionBlur;
@property (nonatomic, copy) NSString *motionSlotID;
@property (nonatomic, copy) NSString *motionNodeID;
@property (nonatomic, readonly) NSView *effectHostView;
@end

@implementation PalmierMotionMaskView {
  CAShapeLayer *_maskShape;
  CIFilter *_blurFilter;
}
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES;
    _motionReveal = 1;
    _maskShape = [CAShapeLayer layer];
    _maskShape.fillColor = NSColor.whiteColor.CGColor;
    _maskShape.actions = @{@"path": NSNull.null};
  }
  return self;
}
- (void)setMotionMask:(NSString *)value { _motionMask = [value copy]; [self updateMotionMask]; }
- (void)setMotionReveal:(CGFloat)value { _motionReveal = value; [self updateMotionMask]; }
- (void)setMotionBlur:(CGFloat)value {
  _motionBlur = value;
  if (value > 0 && !_blurFilter) _blurFilter = [motionBlurTemplate copy];
  [_blurFilter setValue:@(value) forKey:kCIInputRadiusKey];
  self.effectHostView.contentFilters = value > 0 ? @[_blurFilter] : @[];
}
- (void)layout { [super layout]; [self updateMotionMask]; }
- (NSView *)effectHostView {
  NSView *parent = self.superview;
  return [parent isKindOfClass:NSClassFromString(@"RCTLegacyViewManagerInteropComponentView")] ? parent.superview : parent;
}
- (void)viewDidMoveToSuperview { [super viewDidMoveToSuperview]; [self updateMotionMask]; }
- (void)updateMotionMask {
  NSView *host = self.effectHostView;
  if (!host) return;
  host.contentFilters = _motionBlur > 0 && _blurFilter ? @[_blurFilter] : @[];
  if (_motionReveal >= 1 && (!_motionMask || [_motionMask isEqual:@"none"])) { if (host.layer.mask == _maskShape) host.layer.mask = nil; return; }
  CGRect bounds = host.bounds;
  CGRect revealBounds = CGRectMake(0, 0, bounds.size.width * _motionReveal, bounds.size.height);
  CGPathRef reveal = CGPathCreateWithRect(revealBounds, NULL);
  CGPathRef path = reveal;
  if ([_motionMask isEqual:@"ellipse"]) {
    CGPathRef ellipse = CGPathCreateWithEllipseInRect(bounds, NULL);
    path = CGPathCreateCopyByIntersectingPath(ellipse, reveal, false);
    CGPathRelease(ellipse);
  }
  _maskShape.frame = bounds;
  _maskShape.path = path;
  if (path != reveal && path) CGPathRelease(path);
  CGPathRelease(reveal);
  host.layer.mask = _maskShape;
}
@end

@interface PalmierMotionMaskManager : RCTViewManager
@end
@implementation PalmierMotionMaskManager
RCT_EXPORT_MODULE(PalmierMotionMask)
RCT_EXPORT_VIEW_PROPERTY(motionMask, NSString)
RCT_EXPORT_VIEW_PROPERTY(motionReveal, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(motionBlur, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(motionSlotID, NSString)
RCT_EXPORT_VIEW_PROPERTY(motionNodeID, NSString)
- (NSView *)view { return [PalmierMotionMaskView new]; }
@end

static void collectMotionSlots(NSView *view, NSView *root, NSMutableArray *slots) {
  if ([view isKindOfClass:PalmierMotionMaskView.class]) {
    PalmierMotionMaskView *slot = (PalmierMotionMaskView *)view;
    if (slot.motionSlotID.length && slot.motionNodeID.length) {
      NSView *host = slot.effectHostView;
      if (!host) return;
      CGRect bounds = [host.layer convertRect:host.layer.bounds toLayer:root.layer];
      CALayer *parent = host.layer.superlayer;
      CGPoint origin = [parent convertPoint:CGPointZero toLayer:root.layer];
      CGPoint x = [parent convertPoint:CGPointMake(1, 0) toLayer:root.layer];
      CGPoint y = [parent convertPoint:CGPointMake(0, 1) toLayer:root.layer];
      [slots addObject:@{@"nodeID":slot.motionNodeID, @"slotID":slot.motionSlotID,
        @"bounds":@{@"x":@(bounds.origin.x), @"y":@(bounds.origin.y), @"width":@(bounds.size.width), @"height":@(bounds.size.height)},
        @"parentMatrix":@[@(x.x-origin.x), @(x.y-origin.y), @(y.x-origin.x), @(y.y-origin.y), @0, @0]}];
    }
  }
  for (NSView *child in view.subviews) collectMotionSlots(child, root, slots);
}
