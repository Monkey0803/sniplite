/* spike.m: Phase 0 of the macOS port. Answers three questions before any porting:
 *
 *   1. capture:  does ScreenCaptureKit give every display at its native pixel size
 *                (Retina 2x included), and how long does one screenshot take?
 *   2. overlay:  can a borderless NSWindow at CGShieldingWindowLevel cover the menu
 *                bar of the main display (checked on the capture, not by eye)?
 *   3. paste:    does a CGImage written as public.png come back out of NSPasteboard
 *                byte for byte?
 *
 * It writes a JSON report (default /tmp/sniplite-spike/report.json) plus the
 * screenshots it took, so the result can be inspected after the run.
 *
 *   ./build.sh
 *   open -n build/SnipliteSpike.app --args --mode all --report /tmp/sniplite-spike/report.json
 *
 * --mode info | capture | overlay | paste | all (default all). The overlay step
 * shows a magenta strip over every display for ~1.5 s. Nothing here is a product:
 * the real app is ported in the phases that follow. */

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

static NSMutableDictionary *gRep;
static NSString *gOutDir;
static NSString *gReportPath;
static NSUInteger gStepAt;
static NSArray *gSteps;

static void run_next(void);

/* ---- report helpers -------------------------------------------------------------- */

static void rep(NSString *key, id value)
{
    if (value)
        gRep[key] = value;
}

static NSString *now_iso(void)
{
    static NSISO8601DateFormatter *f;
    if (!f)
        f = [NSISO8601DateFormatter new];
    return [f stringFromDate:[NSDate date]];
}

static BOOL save_png(CGImageRef img, NSString *name)
{
    NSURL *url = [NSURL fileURLWithPath:[gOutDir stringByAppendingPathComponent:name]];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (!dst)
        return NO;
    CGImageDestinationAddImage(dst, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return ok;
}

/* One pixel of an image, as 0xRRGGBB (the image is redrawn into a known BGRA buffer). */
static uint32_t pixel_at(CGImageRef img, size_t x, size_t y)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (x >= w || y >= h)
        return 0;
    uint32_t *buf = calloc(w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        free(buf);
        return 0;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    uint32_t p = buf[y * w + x];
    CGContextRelease(ctx);
    free(buf);
    return (p & 0x00FFFFFF); /* BGRA little-endian -> 0x00RRGGBB */
}

static void step(const char *name)
{
    printf("[spike] step %s\n", name);
    fflush(stdout);
}

/* ---- 1. info --------------------------------------------------------------------- */

static void step_info(void)
{
    step("info");
    CGFloat max_top = 0;
    for (NSScreen *s in [NSScreen screens])
        max_top = MAX(max_top, NSMaxY(s.frame));
    NSMutableArray *screens = [NSMutableArray array];
    for (NSScreen *s in [NSScreen screens]) {
        NSNumber *num = s.deviceDescription[@"NSScreenNumber"];
        CGDirectDisplayID did = (CGDirectDisplayID)[num unsignedIntValue];
        CGRect px = CGDisplayBounds(did); /* points */
        NSMutableDictionary *d = [@{
            @"displayID": @(did),
            @"isMain": @(did == CGMainDisplayID()),
            @"framePoints": NSStringFromRect(s.frame),
            @"visibleFramePoints": NSStringFromRect(s.visibleFrame),
            @"backingScale": @(s.backingScaleFactor),
            @"cgBoundsPoints": NSStringFromRect(px),
            @"cgPixelsWide": @(CGDisplayPixelsWide(did)),
            @"cgPixelsHigh": @(CGDisplayPixelsHigh(did)),
            @"topLeftY": @(max_top - NSMaxY(s.frame)),
        } mutableCopy];
        [screens addObject:d];
    }
    rep(@"screens", screens);
    rep(@"shieldingWindowLevel", @(CGShieldingWindowLevel()));
    rep(@"screenRecordingPreflight", @(CGPreflightScreenCaptureAccess()));
    rep(@"osVersion", [[NSProcessInfo processInfo] operatingSystemVersionString]);
    rep(@"bundleID", [[NSBundle mainBundle] bundleIdentifier] ?: @"");
}

/* ---- 2. pasteboard ---------------------------------------------------------------- */

static CGImageRef make_test_image(void)
{
    const size_t w = 64, h = 64;
    uint32_t *buf = calloc(w * h, 4);
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w; x++) {
            uint32_t r = (uint32_t)(x * 255 / (w - 1)), g = (uint32_t)(y * 255 / (h - 1)), b = 0x40;
            uint32_t a = 0xFF;
            /* memory order B,G,R,A (what kCGImageAlphaPremultipliedFirst|32Little means) */
            buf[y * w + x] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(buf);
    return img;
}

static void step_paste(void (^done)(void))
{
    step("paste");
    CGImageRef img = make_test_image();
    NSMutableData *png = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,
                                                                 (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    BOOL ok = dst != NULL;
    if (dst) {
        CGImageDestinationAddImage(dst, img, NULL);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    NSString *pngPath = [gOutDir stringByAppendingPathComponent:@"paste-source.png"];
    [[NSData dataWithData:png] writeToFile:pngPath atomically:YES];

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    BOOL wrote = [pb setData:png forType:UTTypePNG.identifier];
    NSString *types = [[pb types] componentsJoinedByString:@","];
    NSData *back = [pb dataForType:UTTypePNG.identifier];
    CGImageSourceRef src = back ? CGImageSourceCreateWithData((__bridge CFDataRef)back, NULL) : NULL;
    CGImageRef backImg = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    uint32_t p = backImg ? pixel_at(backImg, 63, 0) : 0; /* top-right: red 255, green 0 */

    rep(@"paste", @{
        @"encodeOK": @(ok),
        @"wrotePNG": @(wrote),
        @"types": types ?: @"",
        @"readBackBytes": @(back.length),
        @"roundTripSameSize": @(back.length == png.length),
        @"roundTripPixelOK": @(backImg && (p >> 16) > 0xF0 && ((p >> 8) & 0xFF) < 0x10), /* R high, G low */
        @"sourceFile": pngPath,
    });
    if (backImg)
        CGImageRelease(backImg);
    if (src)
        CFRelease(src);
    CGImageRelease(img);
    done();
}

/* ---- 3. capture ------------------------------------------------------------------- */

static NSMutableArray *gCaptureRows;

static void capture_one(SCDisplay *d, void (^done)(void))
{
    CGFloat scale = 1.0;
    for (NSScreen *s in [NSScreen screens]) {
        CGDirectDisplayID did = (CGDirectDisplayID)[s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if (did == d.displayID) {
            scale = s.backingScaleFactor;
            break;
        }
    }
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]];
    if (@available(macOS 14.2, *))
        filter.includeMenuBar = YES; /* display:excluding already defaults to YES; stated for the report */
    SCStreamConfiguration *cfg = [SCStreamConfiguration new];
    cfg.width = (size_t)lround(d.width * scale);
    cfg.height = (size_t)lround(d.height * scale);
    cfg.showsCursor = NO;
    cfg.captureResolution = SCCaptureResolutionBest;

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    __block BOOL finished = NO;
    __block NSError *err = nil;
    __block CGImageRef shot = NULL;
    __block double ms = 0;

    __block void (^finish)(void);
    finish = ^{
        if (finished)
            return;
        finished = YES;
        double elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        ms = elapsed;
        NSMutableDictionary *row = [@{
            @"displayID": @(d.displayID),
            @"pointsSize": [NSString stringWithFormat:@"%ldx%ld", (long)d.width, (long)d.height],
            @"expectedPixels": [NSString stringWithFormat:@"%zux%zu", cfg.width, cfg.height],
            @"ms": @(ms),
        } mutableCopy];
        if (err) {
            row[@"error"] = [NSString stringWithFormat:@"%@ (%@ %ld)", err.localizedDescription, err.domain, (long)err.code];
        } else if (shot) {
            row[@"pixelsSize"] = [NSString stringWithFormat:@"%zux%zu", CGImageGetWidth(shot), CGImageGetHeight(shot)];
            row[@"matchesExpected"] = @(CGImageGetWidth(shot) == cfg.width && CGImageGetHeight(shot) == cfg.height);
            NSString *name = [NSString stringWithFormat:@"display-%u.png", d.displayID];
            row[@"file"] = name;
            row[@"saved"] = @(save_png(shot, name));
            /* is the frame real content or all black (permission missing)? */
            uint32_t a = pixel_at(shot, CGImageGetWidth(shot) / 3, CGImageGetHeight(shot) / 3);
            uint32_t b = pixel_at(shot, CGImageGetWidth(shot) / 7, CGImageGetHeight(shot) / 5);
            row[@"samplePixels"] = [NSString stringWithFormat:@"%06x %06x", a, b];
            row[@"allBlack"] = @(a == 0 && b == 0);
            CGImageRelease(shot);
            shot = NULL;
        }
        [gCaptureRows addObject:row];
        printf("[spike]   display %u: %s\n", d.displayID, row.description.UTF8String);
        fflush(stdout);
        done();
    };

    void (^timeout)(void) = ^{
        finish();
    };
    [SCScreenshotManager captureImageWithFilter:filter configuration:cfg completionHandler:^(CGImageRef img, NSError *e) {
        if (img)
            shot = CGImageRetain(img);
        err = e;
        dispatch_async(dispatch_get_main_queue(), finish);
    }];
    /* Never hang the spike on a permission dialog: give up after 10 s. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), timeout);
}

static void capture_displays(NSArray<SCDisplay *> *displays, void (^done)(void))
{
    __block NSUInteger i = 0;
    __block void (^next)(void);
    next = ^{
        if (i >= displays.count) {
            done();
            return;
        }
        SCDisplay *d = displays[i++];
        capture_one(d, next);
    };
    next();
}

/* macOS 15.2+: one call for a rectangle in points across displays. */
static void capture_virtual_rect(void (^done)(void))
{
    if (![SCScreenshotManager respondsToSelector:@selector(captureImageInRect:completionHandler:)]) {
        rep(@"captureInRect", @{@"available": @NO});
        done();
        return;
    }
    CGRect uni = CGRectNull;
    for (NSScreen *s in [NSScreen screens])
        uni = CGRectUnion(uni, s.frame);
    CGFloat max_top = 0;
    for (NSScreen *s in [NSScreen screens])
        max_top = MAX(max_top, NSMaxY(s.frame));
    /* NSScreen is bottom-left; SCK takes top-left points for this call. */
    CGRect topLeft = CGRectMake(CGRectGetMinX(uni), max_top - CGRectGetMaxY(uni), uni.size.width, uni.size.height);

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    __block BOOL finished = NO;
    __block void (^finish)(CGImageRef) = ^(CGImageRef img) {
        if (finished)
            return;
        finished = YES;
        NSMutableDictionary *row = [@{
            @"available": @YES,
            @"rectPoints": NSStringFromRect(topLeft),
            @"ms": @((CFAbsoluteTimeGetCurrent() - t0) * 1000.0),
        } mutableCopy];
        if (img) {
            row[@"pixelsSize"] = [NSString stringWithFormat:@"%zux%zu", CGImageGetWidth(img), CGImageGetHeight(img)];
            row[@"saved"] = @(save_png(img, @"virtual-screen.png"));
            CGImageRelease(img);
        }
        rep(@"captureInRect", row);
        printf("[spike]   captureImageInRect: %s\n", row.description.UTF8String);
        fflush(stdout);
        done();
    };
    if (@available(macOS 15.2, *)) {
    [SCScreenshotManager captureImageInRect:topLeft completionHandler:^(CGImageRef img, NSError *e) {
        CGImageRef keep = img ? CGImageRetain(img) : NULL;
        if (e)
            printf("[spike]   captureImageInRect error: %s\n", e.localizedDescription.UTF8String);
        dispatch_async(dispatch_get_main_queue(), ^{ finish(keep); });
    }];
    } else {
        rep(@"captureInRect", @{@"available": @NO});
        done();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(NULL); });
}

static void step_capture(void (^done)(void))
{
    step("capture");
    gCaptureRows = [NSMutableArray array];
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
                                                  completionHandler:^(SCShareableContent *content, NSError *e) {
        if (!content) {
            rep(@"capture", @{@"error": [NSString stringWithFormat:@"%@ (%@ %ld)", e.localizedDescription ?: @"nil content", e.domain, (long)e.code]});
            done();
            return;
        }
        rep(@"shareableDisplays", @([content.displays count]));
        NSArray *sorted = [content.displays sortedArrayUsingComparator:^NSComparisonResult(SCDisplay *a, SCDisplay *b) {
            return a.displayID < b.displayID ? NSOrderedAscending : NSOrderedDescending;
        }];
        capture_displays(sorted, ^{
            rep(@"capture", @{@"displays": gCaptureRows});
            capture_virtual_rect(done);
        });
    }];
}

/* ---- 4. overlay -------------------------------------------------------------------- */

static void step_overlay(void (^done)(void))
{
    step("overlay");
    const CGFloat strip = 80; /* covers the menu bar with room to spare */
    NSMutableArray *wins = [NSMutableArray array];
    CGFloat max_top = 0;
    for (NSScreen *s in [NSScreen screens])
        max_top = MAX(max_top, NSMaxY(s.frame));
    for (NSScreen *s in [NSScreen screens]) {
        NSWindow *w = [[NSWindow alloc] initWithContentRect:s.frame
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
        w.opaque = NO;
        w.backgroundColor = [NSColor clearColor];
        w.hasShadow = NO;
        w.level = (NSWindowLevel)CGShieldingWindowLevel();
        w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                               NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
        w.ignoresMouseEvents = YES;
        NSView *v = [[NSView alloc] initWithFrame:s.frame];
        v.wantsLayer = YES;
        v.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0 alpha:0.18] CGColor];
        CALayer *band = [CALayer layer];
        band.frame = CGRectMake(0, s.frame.size.height - strip, s.frame.size.width, strip); /* top: menu bar */
        band.backgroundColor = [[NSColor magentaColor] CGColor];
        [v.layer addSublayer:band];
        w.contentView = v;
        [w orderFrontRegardless];
        [wins addObject:w];
    }
    rep(@"overlayWindowLevel", @((double)CGShieldingWindowLevel()));
    rep(@"overlayWindows", @(wins.count));

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        /* capture the main display including our overlay, then check the menu bar band */
        __block SCDisplay *mainDisplay = nil;
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
                                                      completionHandler:^(SCShareableContent *content, NSError *e) {
            for (SCDisplay *d in content.displays)
                if (d.displayID == CGMainDisplayID())
                    mainDisplay = d;
            SCDisplay *main = mainDisplay;
            if (!main) {
                rep(@"overlay", @{@"error": @"main display not in shareable content"});
                for (NSWindow *w in wins)
                    [w close];
                done();
                return;
            }
            CGFloat scale = 1.0;
            for (NSScreen *s in [NSScreen screens])
                if ((CGDirectDisplayID)[s.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == main.displayID)
                    scale = s.backingScaleFactor;
            SCContentFilter *f = [[SCContentFilter alloc] initWithDisplay:main excludingWindows:@[]];
            SCStreamConfiguration *cfg = [SCStreamConfiguration new];
            cfg.width = (size_t)lround(main.width * scale);
            cfg.height = (size_t)lround(main.height * scale);
            cfg.showsCursor = NO;
            cfg.captureResolution = SCCaptureResolutionBest;
            [SCScreenshotManager captureImageWithFilter:f configuration:cfg completionHandler:^(CGImageRef img, NSError *err) {
                NSMutableDictionary *row = [@{} mutableCopy];
                if (img) {
                    CGImageRef keep = CGImageRetain(img);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        uint32_t top = pixel_at(keep, 40, (size_t)lround(10 * scale));  /* inside menu bar */
                        uint32_t low = pixel_at(keep, 40, (size_t)lround(60 * scale));  /* strip below it */
                        uint32_t below = pixel_at(keep, 40, (size_t)lround(strip * scale + 40 * scale));
                        row[@"menuBarPixel"] = [NSString stringWithFormat:@"%06x", top];
                        row[@"stripPixel"] = [NSString stringWithFormat:@"%06x", low];
                        row[@"belowStripPixel"] = [NSString stringWithFormat:@"%06x", below];
                        row[@"coversMenuBar"] = @((top >> 16) > 0xE0 && ((top >> 8) & 0xFF) < 0x20 && (top & 0xFF) > 0xE0);
                        row[@"saved"] = @(save_png(keep, @"overlay-proof.png"));
                        rep(@"overlay", row);
                        printf("[spike]   overlay: %s\n", row.description.UTF8String);
                        fflush(stdout);
                        CGImageRelease(keep);
                        for (NSWindow *w in wins)
                            [w close];
                        done();
                    });
                } else {
                    row[@"error"] = err.localizedDescription ?: @"capture failed";
                    rep(@"overlay", row);
                    for (NSWindow *w in wins)
                        [w close];
                    done();
                }
            }];
        }];
    });
}

/* ---- runner ------------------------------------------------------------------------- */

static void finish(void)
{
    rep(@"finishedAt", now_iso());
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:gRep options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&err];
    if (!json) {
        fprintf(stderr, "[spike] cannot serialize report: %s\n", err.localizedDescription.UTF8String);
        exit(2);
    }
    [json writeToFile:gReportPath atomically:YES];
    fwrite(json.bytes, 1, json.length, stdout);
    printf("\n[spike] report: %s\n", gReportPath.UTF8String);
    fflush(stdout);
    exit(0);
}

static void run_next(void)
{
    if (gStepAt >= gSteps.count) {
        finish();
        return;
    }
    void (^s)(void (^)(void)) = gSteps[gStepAt++];
    s(^{ run_next(); });
}

static int usage(void)
{
    fprintf(stderr, "usage: SnipliteSpike [--mode info|capture|overlay|paste|all] [--report PATH] [--out DIR]\n");
    return 2;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *mode = @"all";
        gReportPath = @"/tmp/sniplite-spike/report.json";
        gOutDir = @"/tmp/sniplite-spike";
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--mode") && i + 1 < argc)
                mode = @(argv[++i]);
            else if (!strcmp(argv[i], "--report") && i + 1 < argc)
                gReportPath = @(argv[++i]);
            else if (!strcmp(argv[i], "--out") && i + 1 < argc)
                gOutDir = @(argv[++i]);
            else
                return usage();
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:gOutDir withIntermediateDirectories:YES attributes:nil error:NULL];
        [[NSFileManager defaultManager] createDirectoryAtPath:[gReportPath stringByDeletingLastPathComponent]
                                    withIntermediateDirectories:YES attributes:nil error:NULL];

        gRep = [NSMutableDictionary dictionary];
        rep(@"mode", mode);
        rep(@"startedAt", now_iso());
        rep(@"pid", @([[NSProcessInfo processInfo] processIdentifier]));

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSMutableArray *steps = [NSMutableArray array];
        void (^infoStep)(void (^)(void)) = ^(void (^next)(void)) { step_info(); next(); };
        if ([mode isEqualToString:@"info"] || [mode isEqualToString:@"all"])
            [steps addObject:infoStep];
        if ([mode isEqualToString:@"paste"] || [mode isEqualToString:@"all"])
            [steps addObject:^(void (^next)(void)) { step_paste(next); }];
        if ([mode isEqualToString:@"capture"] || [mode isEqualToString:@"all"])
            [steps addObject:^(void (^next)(void)) { step_capture(next); }];
        if ([mode isEqualToString:@"overlay"] || [mode isEqualToString:@"all"])
            [steps addObject:^(void (^next)(void)) { step_overlay(next); }];
        if (steps.count == 0)
            return usage();

        gSteps = steps;
        dispatch_async(dispatch_get_main_queue(), ^{ run_next(); });
        [NSApp run];
    }
    return 0;
}
