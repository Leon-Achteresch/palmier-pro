#import "PalmierRNHost.h"

#import <AppKit/AppKit.h>
#import <RCTDefaultReactNativeFactoryDelegate.h>
#import <RCTReactNativeFactory.h>
#import <React/RCTViewManager.h>
#import "PalmierMotionViews.inc"
#import "PalmierMotionCapture.inc"

#include <hermes/hermes.h>
#include <jsi/jsi.h>

#include <memory>
#include <string>

@implementation PalmierRNHost

+ (BOOL)prepareRendering { return prepareMotionFilters(); }

+ (nullable NSString *)evaluateScript:(NSString *)source error:(NSError **)error {
  try {
    auto runtime = facebook::hermes::makeHermesRuntime();
    auto buffer = std::make_shared<facebook::jsi::StringBuffer>(std::string(source.UTF8String));
    auto value = runtime->evaluateJavaScript(buffer, "palmier-smoke.js");
    return @(value.toString(*runtime).utf8(*runtime).c_str());
  } catch (const std::exception &problem) {
    if (error) {
      *error = [NSError errorWithDomain:@"PalmierRNHost"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: @(problem.what())}];
    }
    return nil;
  }
}

@end

@interface PalmierRNFactoryDelegate : RCTDefaultReactNativeFactoryDelegate
@property (nonatomic, copy) NSURL *sceneBundleURL;
@property (nonatomic, copy, nullable) NSString *capturedError;
@end

@implementation PalmierRNFactoryDelegate

- (NSURL *)bundleURL {
  return self.sceneBundleURL;
}

- (NSURL *)sourceURLForBridge:(RCTBridge *)bridge {
  return self.sceneBundleURL;
}

- (void)host:(RCTHost *)host
    didReceiveJSErrorStack:(NSArray<NSDictionary<NSString *, id> *> *)stack
                   message:(NSString *)message
           originalMessage:(NSString *_Nullable)originalMessage
                      name:(NSString *_Nullable)name
            componentStack:(NSString *_Nullable)componentStack
               exceptionId:(NSUInteger)exceptionId
                   isFatal:(BOOL)isFatal
                 extraData:(NSDictionary<NSString *, id> *)extraData {
  if (!self.capturedError) self.capturedError = originalMessage.length ? originalMessage : message;
}

@end

/// RN's own root and surface views paint opaque, which would bake the surround out solid. Only
/// those are cleared — recursing into the scene's views would wipe the colours it actually set.
static void clearHostBackgrounds(NSView *view) {
  NSString *name = NSStringFromClass(view.class);
  if (![name containsString:@"Surface"] && ![name containsString:@"RootView"]) return;

  view.wantsLayer = YES;
  view.layer.backgroundColor = NSColor.clearColor.CGColor;
  view.layer.opaque = NO;
  if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
    [view setValue:NSColor.clearColor forKey:@"backgroundColor"];
  }
  for (NSView *child in view.subviews) clearHostBackgrounds(child);
}

static NSString *const PalmierFrameCommitted = @"PalmierFrameCommitted";

@interface PalmierFrameMarkerView : NSView
@property (nonatomic, copy) NSString *payload;
@end

@implementation PalmierFrameMarkerView
- (void)setPayload:(NSString *)payload {
  _payload = [payload copy];
  NSDictionary *receipt = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  if (![receipt isKindOfClass:NSDictionary.class]) return;
  // Delivery after the mount transaction ensures every view has received its frame properties.
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:PalmierFrameCommitted object:nil userInfo:receipt];
  });
}
@end

@interface PalmierFrameMarkerManager : RCTViewManager
@end
@implementation PalmierFrameMarkerManager
RCT_EXPORT_MODULE(PalmierFrameMarker)
RCT_EXPORT_VIEW_PROPERTY(payload, NSString)
- (NSView *)view { return [PalmierFrameMarkerView new]; }
@end

@implementation PalmierRNSurface {
  NSURL *_bundleURL;
  NSSize _size;
  NSWindow *_window;
  PalmierRNFactoryDelegate *_delegate;
  RCTReactNativeFactory *_factory;
  NSView *_rootView;
  id _frameObserver;
  NSString *_pendingRequest;
  NSString *_frameError;
  void (^_pendingCompletion)(NSError *);
  PalmierMotionCapture *_capture;

}

- (instancetype)initWithBundleURL:(NSURL *)bundleURL width:(NSInteger)width height:(NSInteger)height {
  if ((self = [super init])) {
    _bundleURL = bundleURL;
    _size = NSMakeSize(width, height);
  }
  return self;
}

- (void)startWithSceneSource:(NSString *)source
                         fps:(double)fps
            durationInFrames:(NSInteger)durationInFrames
                  completion:(void (^)(NSError *_Nullable))completion {
  NSAssert(NSThread.isMainThread, @"React Native must be started on the main thread");
  [self beginRequest:completion];
  __weak PalmierRNSurface *weakSelf = self;
  _frameObserver = [[NSNotificationCenter defaultCenter] addObserverForName:PalmierFrameCommitted object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
    [weakSelf receiveFrame:notification.userInfo];
  }];

  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-30000, -30000, _size.width, _size.height)
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  _window.opaque = NO;
  _window.backgroundColor = NSColor.clearColor;
  _window.ignoresMouseEvents = YES;
  _window.excludedFromWindowsMenu = YES;

  _delegate = [PalmierRNFactoryDelegate new];
  _delegate.sceneBundleURL = _bundleURL;

  @try {
    _factory = [[RCTReactNativeFactory alloc] initWithDelegate:_delegate];
    _rootView = [_factory.rootViewFactory viewWithModuleName:@"PalmierScene"
                           initialProperties:@{
                             @"source": source,
                             @"requestID": _pendingRequest,
                             @"fps": @(fps),
                             @"width": @(_size.width),
                             @"height": @(_size.height),
                             @"durationInFrames": @(durationInFrames)
                           }
                               launchOptions:nil];
    _rootView.frame = NSMakeRect(0, 0, _size.width, _size.height);
    _window.contentView = _rootView;
    [_window orderBack:nil];
  } @catch (NSException *exception) {
    [self finishRequest:[NSError errorWithDomain:@"PalmierRNHost"
                                   code:2
                               userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}]];
    return;
  }

}

- (nullable NSString *)sceneError { return _frameError ?: _delegate.capturedError; }

- (NSView *)presentationView { return _rootView; }

- (NSString *)slotBoundsJSON {
  NSMutableArray *slots = [NSMutableArray array];
  collectMotionSlots(_rootView, _rootView, slots);
  NSData *data = [NSJSONSerialization dataWithJSONObject:slots options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
}

- (void)beginRequest:(void (^)(NSError *))completion {
  if (_pendingCompletion) [self finishRequest:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
  _pendingRequest = NSUUID.UUID.UUIDString;
  _pendingCompletion = [completion copy];
}

- (void)finishRequest:(NSError *)error {
  void (^completion)(NSError *) = _pendingCompletion;
  _pendingCompletion = nil;
  _pendingRequest = nil;
  if (completion) completion(error);
}

- (void)receiveFrame:(NSDictionary *)receipt {
  if (![_pendingRequest isEqual:receipt[@"requestID"]]) return;
  NSString *error = [receipt[@"error"] isKindOfClass:NSString.class] ? receipt[@"error"] : nil;
  if (error.length) _frameError = error;
  [_rootView layoutSubtreeIfNeeded];
  [_rootView displayIfNeeded];
  restoreMotionMasks(_rootView);
  [self finishRequest:self.sceneError ? [NSError errorWithDomain:@"PalmierRNHost" code:3 userInfo:@{NSLocalizedDescriptionKey:self.sceneError}] : nil];
}

- (void)seekToMilliseconds:(double)milliseconds completion:(void (^)(NSError *))completion {
  [self beginRequest:completion];
  [_factory.rootViewFactory.reactHost callFunctionOnJSModule:@"PalmierMotion" method:@"seek" args:@[@(milliseconds), _pendingRequest]];
}

- (void)updateDocument:(NSString *)json completion:(void (^)(NSError *))completion {
  _frameError = nil;
  [self beginRequest:completion];
  [_factory.rootViewFactory.reactHost callFunctionOnJSModule:@"PalmierMotion" method:@"update" args:@[json, _pendingRequest]];
}

- (void)tearDown {
  [self finishRequest:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
  if (_frameObserver) [[NSNotificationCenter defaultCenter] removeObserver:_frameObserver];
  _frameObserver = nil;
  [_rootView removeFromSuperview];
  [_window orderOut:nil];
  _rootView = nil;
  _factory = nil;
  _window = nil;
  _capture = nil;
}

- (void)captureSnapshotWithCompletion:(void (^)(CGImageRef, NSError *))completion {
  if (!_rootView) { completion(NULL, motionCaptureError(@"The native scene has closed")); return; }
  clearHostBackgrounds(_rootView);
  if (!_capture) _capture = [PalmierMotionCapture new];
  [_capture captureView:_rootView size:_size completion:completion];
}

@end
