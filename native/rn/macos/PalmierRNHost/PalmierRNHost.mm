#import "PalmierRNHost.h"

#import <AppKit/AppKit.h>
#import <RCTDefaultReactNativeFactoryDelegate.h>
#import <RCTReactNativeFactory.h>

#include <hermes/hermes.h>
#include <jsi/jsi.h>

#include <memory>
#include <string>

@implementation PalmierRNHost

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

@implementation PalmierRNSurface {
  NSURL *_bundleURL;
  NSSize _size;
  NSWindow *_window;
  PalmierRNFactoryDelegate *_delegate;
  RCTReactNativeFactory *_factory;
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

  // An offscreen NSView only composites once it belongs to a window, and the window must stay
  // non-opaque or the surround bakes out black instead of transparent.
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, _size.width, _size.height)
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  _window.opaque = NO;
  _window.backgroundColor = NSColor.clearColor;

  _delegate = [PalmierRNFactoryDelegate new];
  _delegate.sceneBundleURL = _bundleURL;

  @try {
    _factory = [[RCTReactNativeFactory alloc] initWithDelegate:_delegate];
    [_factory startReactNativeWithModuleName:@"PalmierScene"
                                    inWindow:_window
                           initialProperties:@{
                             @"source": source,
                             @"fps": @(fps),
                             @"width": @(_size.width),
                             @"height": @(_size.height),
                             @"durationInFrames": @(durationInFrames)
                           }
                               launchOptions:nil];
  } @catch (NSException *exception) {
    completion([NSError errorWithDomain:@"PalmierRNHost"
                                   code:2
                               userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}]);
    return;
  }

  completion(nil);
}

- (nullable NSString *)sceneError {
  return _delegate.capturedError;
}

- (void)seekToMilliseconds:(double)milliseconds {
  [_factory.rootViewFactory.reactHost callFunctionOnJSModule:@"PalmierMotion"
                                                      method:@"seek"
                                                        args:@[@(milliseconds)]];
}

- (nullable CGImageRef)copySnapshot {
  NSView *view = _window.contentView;
  if (!view) return NULL;
  clearHostBackgrounds(view);

  NSBitmapImageRep *representation = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
  if (!representation) return NULL;
  [view cacheDisplayInRect:view.bounds toBitmapImageRep:representation];

  CGImageRef image = representation.CGImage;
  return image ? (CGImageRef)CFRetain(image) : NULL;
}

@end
