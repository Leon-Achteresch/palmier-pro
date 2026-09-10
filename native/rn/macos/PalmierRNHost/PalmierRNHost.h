#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Facade over react-native-macos. Everything RN stays behind this header so SwiftPM never sees it.
@interface PalmierRNHost : NSObject

+ (BOOL)prepareRendering;
+ (nullable NSString *)evaluateScript:(NSString *)source error:(NSError **)error;

@end

/// One offscreen React Native surface, sized in pixels, snapshotted per baked frame.
@interface PalmierRNSurface : NSObject

- (instancetype)initWithBundleURL:(NSURL *)bundleURL
                            width:(NSInteger)width
                           height:(NSInteger)height NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)startWithSceneSource:(NSString *)source
                         fps:(double)fps
            durationInFrames:(NSInteger)durationInFrames
                  completion:(void (^)(NSError *_Nullable error))completion;
- (void)seekToMilliseconds:(double)milliseconds completion:(void (^)(NSError *_Nullable error))completion;
- (void)updateDocument:(NSString *)json completion:(void (^)(NSError *_Nullable error))completion;
- (void)tearDown;
@property (nonatomic, readonly) NSView *presentationView;
@property (nonatomic, readonly) NSString *slotBoundsJSON;

/// Non-nil once the scene has thrown. Baking must fail rather than ship blank frames.
@property (nonatomic, readonly, nullable) NSString *sceneError;
- (void)captureSnapshotWithCompletion:(void (^)(CGImageRef _Nullable image, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
