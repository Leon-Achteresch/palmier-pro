#import <AppKit/AppKit.h>

#import "PalmierRNHost.h"

// Dev-only harness. Offscreen compositing needs a real NSApplication, which the SwiftPM test
// process does not have, so the render proof lives here instead of in a unit test.

static void pump(NSTimeInterval seconds) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (deadline.timeIntervalSinceNow > 0) {
    [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  }
}

static size_t opaquePixels(CGImageRef image, NSString *outputPath) {
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
  if (outputPath) {
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:outputPath
                                                                           atomically:YES];
  }
  size_t opaque = 0;
  for (size_t y = 0; y < CGImageGetHeight(image); y += 2) {
    for (size_t x = 0; x < CGImageGetWidth(image); x += 2) {
      if ([rep colorAtX:x y:y].alphaComponent > 0.05) opaque++;
    }
  }
  return opaque;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 3) {
      fprintf(stderr, "usage: harness <main.jsbundle> <out-prefix>\n");
      return 2;
    }

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];

    NSString *scene = @"import { View } from \"react-native\"\n"
                       "export default function Scene() {\n"
                       "  const t = PalmierMotion.useSceneTime()\n"
                       "  return (\n"
                       "    <View style={{ flex: 1, justifyContent: \"center\" }}>\n"
                       "      <View style={{ height: 120, width: 40 + t * 400, backgroundColor: \"#00c853\" }} />\n"
                       "    </View>\n"
                       "  )\n"
                       "}\n";

    PalmierRNSurface *surface =
        [[PalmierRNSurface alloc] initWithBundleURL:[NSURL fileURLWithPath:@(argv[1])]
                                              width:640
                                             height:360];

    __block NSError *failure = nil;
    [surface startWithSceneSource:scene fps:30 completion:^(NSError *error) { failure = error; }];
    if (failure) {
      fprintf(stderr, "start failed: %s\n", failure.localizedDescription.UTF8String);
      return 1;
    }
    pump(6.0);

    CGImageRef first = [surface copySnapshot];
    if (!first) { fprintf(stderr, "snapshot at 0ms returned null\n"); return 1; }
    size_t atZero = opaquePixels(first, [NSString stringWithFormat:@"%s-0ms.png", argv[2]]);
    CFRelease(first);

    [surface seekToMilliseconds:1000];
    pump(1.5);

    CGImageRef second = [surface copySnapshot];
    if (!second) { fprintf(stderr, "snapshot at 1000ms returned null\n"); return 1; }
    size_t atOneSecond = opaquePixels(second, [NSString stringWithFormat:@"%s-1000ms.png", argv[2]]);
    CFRelease(second);

    printf("opaque@0ms=%zu  opaque@1000ms=%zu  %s\n", atZero, atOneSecond,
           atOneSecond > atZero ? "TIMELINE ADVANCES" : "STATIC — seek had no effect");
    return atOneSecond > atZero ? 0 : 1;
  }
}
