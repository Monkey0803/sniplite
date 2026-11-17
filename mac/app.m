/* app.m: the background application of the macOS port.
 *
 * An agent application (no Dock icon) with a status bar item and its menu, the global
 * hotkeys, one instance only, the settings file the shared config.c reads, the language
 * table of the shared lang.c, and the hooks the other modules report through: capture
 * (overlay.m), pins (pin.m), the preferences window (settings.m), the long screenshot
 * (longscreen.m).
 *
 * The Windows daemon has a window, a message loop and helper processes. None of that
 * survives here: the run loop is NSApplication's, the "daemon" is this app, and there is
 * no IPC (a second launch activates the first). */
#import <Cocoa/Cocoa.h>

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

#include "capture.h"
#include "config.h"
#include "hotkey.h"
#include "lang.h"
#include "longscreen.h"
#include "overlay.h"
#include "pin.h"
#include "plat.h"
#include "settings.h"

static Config g_config;
static NSStatusItem *g_status;
static int g_lock_fd = -1;

static bool ui_zh(void)
{
    int l = lang_choice();
    if (l == LG_AUTO)
        l = lang_system();
    return l == LG_ZH_CN || l == LG_ZH_TW;
}

static NSString *tr(NSString *en, NSString *zh) { return ui_zh() ? zh : en; }

static NSString *ns(const WCHAR *s)
{
    char *u = snip_wstr_to_utf8(s);
    NSString *r = u ? [NSString stringWithUTF8String:u] : @"";
    free(u);
    return r;
}

/* ---- a small HUD, for what has no window of its own -------------------------------- */

static void snip_hud(NSString *text)
{
    NSDictionary *attrs = @{NSFontAttributeName : [NSFont systemFontOfSize:13]};
    NSSize ts = [text sizeWithAttributes:attrs];
    CGFloat w = ts.width + 28, h = ts.height + 18;
    NSPoint mouse = [NSEvent mouseLocation]; /* bottom-left of the main screen */
    NSScreen *screen = nil;
    for (NSScreen *s in [NSScreen screens])
        if (NSPointInRect(mouse, s.frame)) {
            screen = s;
            break;
        }
    if (!screen)
        screen = [NSScreen mainScreen];
    NSRect vf = screen.visibleFrame;
    CGFloat x = MIN(MAX(mouse.x + 16, vf.origin.x), vf.origin.x + vf.size.width - w);
    CGFloat y = MIN(MAX(mouse.y - h - 16, vf.origin.y), vf.origin.y + vf.size.height - h);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(x, y, w, h)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.opaque = NO;
    win.backgroundColor = [NSColor clearColor];
    win.hasShadow = YES;
    win.level = NSStatusWindowLevel;
    win.ignoresMouseEvents = YES;
    win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                             NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    v.wantsLayer = YES;
    v.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.10 alpha:0.92].CGColor;
    v.layer.cornerRadius = 8;
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:13];
    label.textColor = [NSColor whiteColor];
    label.frame = NSMakeRect(14, (h - ts.height) / 2, ts.width, ts.height);
    [v addSubview:label];
    win.contentView = v;
    [win orderFrontRegardless];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [win close];
    });
}

/* ---- a debug pin, for looking at the pinned window without a hotkey ------------------- */

static void release_px(void *info, const void *data, size_t size)
{
    (void)info;
    (void)size;
    free((void *)data);
}

static void pin_demo(void)
{
    int w = 360, h = 240;
    uint32_t *px = calloc((size_t)w * h, 4);
    if (!px)
        return;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            int r = 40 + 180 * x / w, g = 60 + 140 * y / h, b = 200 - 120 * x / w;
            px[(size_t)y * w + x] = 0xFF000000u | (uint32_t)((r << 16) | (g << 8) | b);
        }
    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, px, (size_t)w * h * 4, release_px);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs,
                                   kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, prov, NULL, false,
                                   kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(prov);
    if (!img)
        return;
    pin_create(img, 400, 300);
    CGImageRelease(img);
    snip_log("pin demo up");
}

/* ---- the menu's hotkey text --------------------------------------------------------- */

static NSString *pretty_hotkey(int id)
{
    WCHAR buf[64];
    hotkey_format(g_config.mod[id], g_config.vk[id], buf);
    NSString *s = ns(buf);
    s = [s stringByReplacingOccurrencesOfString:@"Ctrl+" withString:@"⌃"];
    s = [s stringByReplacingOccurrencesOfString:@"Alt+" withString:@"⌥"];
    s = [s stringByReplacingOccurrencesOfString:@"Shift+" withString:@"⇧"];
    s = [s stringByReplacingOccurrencesOfString:@"Win+" withString:@"⌘"];
    return s;
}

static NSString *menu_title(int s, int id)
{
    NSString *t = ns(g_tr[s]);
    if (id > 0 && id < HK_COUNT)
        return [NSString stringWithFormat:@"%@  %@", t, pretty_hotkey(id)];
    return t;
}

@interface SnipDelegate : NSObject <NSApplicationDelegate>
- (NSImage *)statusImage;
- (void)buildMenu;
- (void)updatePinItem;
- (void)configChanged:(NSNotification *)note;
- (void)screensChanged:(NSNotification *)note;
- (void)capture:(id)sender;
- (void)pin:(id)sender;
- (void)togglePins:(id)sender;
- (void)settings:(id)sender;
- (void)about:(id)sender;
@end

static SnipDelegate *g_delegate;

/* ---- what the hotkeys and the menu do ------------------------------------------------ */

static void do_capture(void)
{
    if (!ov_begin())
        snip_log("capture not started (busy or no permission)");
}

static void pin_clipboard(void)
{
    if (!pin_from_clipboard())
        snip_hud(tr(@"the clipboard has no image or text", @"剪贴板里没有图片或文字"));
}

static bool pin_toggle(void)
{
    if (!pin_count()) {
        snip_hud(tr(@"no pins yet", @"还没有贴图"));
        return false;
    }
    pin_toggle_all();
    snip_hud(pin_all_hidden() ? tr(@"pins hidden", @"贴图已隐藏") : tr(@"pins shown", @"贴图已显示"));
    return true;
}

static void on_global_hotkey(int id)
{
    snip_log("hotkey %d", id);
    switch (id) {
    case HK_CAPTURE: do_capture(); break;
    case HK_PIN: pin_clipboard(); break;
    case HK_TOGGLE:
        if (pin_toggle())
            dispatch_async(dispatch_get_main_queue(), ^{
              [g_delegate updatePinItem];
            });
        break;
    default: break;
    }
}

/* ---- the application ------------------------------------------------------------------ */



@implementation SnipDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    (void)note;
    /* one instance: a second launch activates the first and leaves */
    WCHAR dir[1024], ini[1024];
    snip_support_dir(dir, COUNTOF(dir));
    NSString *lockPath = [ns(dir) stringByAppendingPathComponent:@".lock"];
    g_lock_fd = open([lockPath fileSystemRepresentation], O_CREAT | O_RDWR, 0600);
    if (g_lock_fd >= 0 && flock(g_lock_fd, LOCK_EX | LOCK_NB) != 0) {
        g_lock_fd = -1;
        NSArray *others = [NSRunningApplication runningApplicationsWithBundleIdentifier:[[NSBundle mainBundle] bundleIdentifier]];
        for (NSRunningApplication *a in others)
            if (a.processIdentifier != getpid())
                [a activateWithOptions:0]; /* activating an already-running instance */
        snip_log("already running, activated it");
        [NSApp terminate:nil];
        return;
    }

    lang_init(NULL); /* the language from sniplite.ini, or the system one */
    config_load(&g_config);
    pin_set_top(g_config.pin_top);
    ini_path(ini, COUNTOF(ini));

    hk_init(on_global_hotkey);
    bool ok[HK_COUNT] = {0};
    hk_apply(&g_config, ok);
    char *ver = snip_wstr_to_utf8(SNIPLITE_VERSION), *inip = snip_wstr_to_utf8(ini);
    snip_log("started v%s, pid %d, lang %d, ini %s", ver ?: "?", (int)getpid(), lang_choice(), inip ?: "?");
    free(ver);
    free(inip);
    snip_log("hotkeys: capture %d, pin %d, toggle %d", ok[HK_CAPTURE], ok[HK_PIN], ok[HK_TOGGLE]);

    cap_prewarm(); /* resolve the displays now, not on the first hotkey */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(configChanged:)
                                                 name:SnipConfigChangedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screensChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];

    g_status = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    g_status.button.image = [self statusImage];
    g_status.button.image.template = YES;
    g_status.button.toolTip = [NSString stringWithFormat:@"sniplite %@", ns(SNIPLITE_VERSION)];
    g_status.visible = YES; /* a crowded menu bar hides new items; ask for the room */
    [self buildMenu];
    snip_log("status item %s", g_status.isVisible ? "visible" : "hidden (menu bar full)");
}

/* a preference was written: reload it, register the hotkeys again and rebuild the menu */
- (void)configChanged:(NSNotification *)note
{
    (void)note;
    config_load(&g_config);
    bool ok[HK_COUNT] = {0};
    hk_apply(&g_config, ok);
    pin_set_top(g_config.pin_top);
    [self buildMenu];
    NSMutableArray *results = [NSMutableArray array];
    for (int i = 0; i < HK_COUNT; i++)
        [results addObject:@(ok[i])];
    [[NSNotificationCenter defaultCenter] postNotificationName:SnipHotkeysChangedNotification
                                                        object:nil
                                                      userInfo:@{@"ok" : results}];
    snip_log("settings applied: hotkeys %d %d %d", ok[HK_CAPTURE], ok[HK_PIN], ok[HK_TOGGLE]);
}

- (void)screensChanged:(NSNotification *)note
{
    (void)note;
    snip_log("displays changed");
    cap_invalidate();
    cap_prewarm();
    if (ov_active())
        ov_cancel();
    if (long_active())
        long_cancel(); /* the region may not be on any display any more */
}

- (NSImage *)statusImage
{
    /* A frame with a dot in it: the capture area and the pin, drawn so the menu bar can
     * tint it (template image). */
    return [NSImage imageWithSize:NSMakeSize(18, 18)
                          flipped:NO
                   drawingHandler:^BOOL(NSRect r) {
                     (void)r;
                     [[NSColor blackColor] setStroke];
                     NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2.5, 4.5, 13, 11)
                                                                          xRadius:2.5
                                                                          yRadius:2.5];
                     frame.lineWidth = 1.6;
                     [frame stroke];
                     [[NSColor blackColor] setFill];
                     [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(9.5, 1.5, 6, 6)] fill];
                     return YES;
                   }];
}

- (void)buildMenu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"sniplite"];
    NSMenuItem *it;

    it = [[NSMenuItem alloc] initWithTitle:menu_title(S_M_CAPTURE, HK_CAPTURE) action:@selector(capture:) keyEquivalent:@""];
    it.target = self;
    [menu addItem:it];
    it = [[NSMenuItem alloc] initWithTitle:menu_title(S_M_PIN, HK_PIN) action:@selector(pin:) keyEquivalent:@""];
    it.target = self;
    [menu addItem:it];
    it = [[NSMenuItem alloc] initWithTitle:menu_title(pin_all_hidden() ? S_M_SHOW_PINS : S_M_HIDE_PINS, HK_TOGGLE)
                                    action:@selector(togglePins:)
                             keyEquivalent:@""];
    it.target = self;
    [menu addItem:it];
    [menu addItem:[NSMenuItem separatorItem]];
    it = [[NSMenuItem alloc] initWithTitle:ns(T(M_SETTINGS)) action:@selector(settings:) keyEquivalent:@","];
    it.target = self;
    [menu addItem:it];
    it = [[NSMenuItem alloc] initWithTitle:ns(T(M_ABOUT)) action:@selector(about:) keyEquivalent:@""];
    it.target = self;
    [menu addItem:it];
    [menu addItem:[NSMenuItem separatorItem]];
    it = [[NSMenuItem alloc] initWithTitle:ns(T(M_EXIT)) action:@selector(terminate:) keyEquivalent:@"q"];
    [menu addItem:it];
    g_status.menu = menu;
}

- (void)updatePinItem
{
    for (NSMenuItem *it in g_status.menu.itemArray)
        if (it.action == @selector(togglePins:))
            it.title = menu_title(pin_all_hidden() ? S_M_SHOW_PINS : S_M_HIDE_PINS, HK_TOGGLE);
}

- (void)capture:(id)sender
{
    (void)sender;
    do_capture();
}

- (void)pin:(id)sender
{
    (void)sender;
    pin_clipboard();
}

- (void)togglePins:(id)sender
{
    (void)sender;
    if (pin_toggle())
        [self updatePinItem];
}

- (void)settings:(id)sender
{
    (void)sender;
    settings_open();
}

- (void)about:(id)sender
{
    (void)sender;
    NSAlert *a = [NSAlert new];
    a.messageText = @"sniplite";
    char *v = snip_wstr_to_utf8(SNIPLITE_VERSION);
    a.informativeText = [NSString stringWithFormat:@"%s\n%@\n\n%@", v ?: "?", ns(T(TAGLINE)),
                                                   @"macOS port: capture, annotations, pins, long screenshot.\n"
                                                   @"Screen recording is granted in System Settings."];
    free(v);
    [a addButtonWithTitle:ns(T(OK_BTN))];
    [a runModal];
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    (void)note;
    hk_release();
    snip_log("quit");
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    (void)sender;
    return NO;
}

@end

static int usage(void)
{
    fprintf(stderr, "usage: sniplite [--capture] [--settings] [--long] [--pin-demo] [--version] [--help]\n");
    return 2;
}

int main(int argc, char *argv[])
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-v")) {
            char *v = snip_wstr_to_utf8(SNIPLITE_VERSION);
            printf("%s (macOS)\n", v ?: "sniplite");
            free(v);
            return 0;
        }
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h"))
            return usage();
    }
    bool capture_now = false, settings_now = false, long_now = false, pin_now = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--capture"))
            capture_now = true;
        if (!strcmp(argv[i], "--settings"))
            settings_now = true;
        if (!strcmp(argv[i], "--long"))
            long_now = true;
        if (!strcmp(argv[i], "--pin-demo"))
            pin_now = true;
    }
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_delegate = [SnipDelegate new];
        app.delegate = g_delegate;
        if (pin_now)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
              pin_demo();
            });
        if (settings_now)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
              settings_open();
            });
        if (capture_now)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
              do_capture();
            });
        if (long_now) /* a fixed region: for looking at the windows without a hotkey */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
              CGFloat top = 0;
              for (NSScreen *s in [NSScreen screens])
                  top = MAX(top, NSMaxY(s.frame));
              RECT rc = {400, (LONG)(top - 1040), 900, (LONG)(top - 640)};
              if (!long_begin(rc))
                  snip_log("--long: could not start");
            });
        [app run];
    }
    return 0;
}