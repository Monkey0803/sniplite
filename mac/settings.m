/* settings.m: the preferences window of the macOS port.
 *
 * Four pages (general, capture, hotkeys, about) instead of the Windows dialog's six: the
 * update page and the OCR page belong to features the port has not taken over. Every
 * change is written to sniplite.ini at once and announced with
 * SnipConfigChangedNotification; the app re-registers the hotkeys and rebuilds its menu,
 * so nothing waits for an OK button, like the Windows window.
 *
 * The hotkey fields record a combination: click one and press the keys; hotkey.c's
 * inverse map turns the event back into "Ctrl+Alt+1". The label beside it turns red when
 * the system refused that combination (or macOS has no such key). */
#import <Cocoa/Cocoa.h>

#include <stdlib.h>
#include <string.h>

#include "config.h"
#include "hotkey.h"
#include "lang.h"
#include "plat.h"
#include "pin.h"
#include "settings.h"

NSString *const SnipConfigChangedNotification = @"SnipConfigChanged";
NSString *const SnipHotkeysChangedNotification = @"SnipHotkeysChanged";

static NSString *wstr(const WCHAR *s)
{
    char *u = snip_wstr_to_utf8(s);
    NSString *r = u ? [NSString stringWithUTF8String:u] : @"";
    free(u);
    return r;
}

static bool ui_zh(void)
{
    int l = lang_choice();
    if (l == LG_AUTO)
        l = lang_system();
    return l == LG_ZH_CN || l == LG_ZH_TW;
}

static NSString *tr(NSString *en, NSString *zh) { return ui_zh() ? zh : en; }

static NSTextField *label_plain(NSView *v, NSString *text, NSRect r);
static void label_note(NSView *v, NSString *text, NSRect r);

static void apply_config(const Config *c)
{
    config_save(c);
    [[NSNotificationCenter defaultCenter] postNotificationName:SnipConfigChangedNotification object:nil];
}

/* ---- the hotkey recorder ----------------------------------------------------------------- */

@interface HotkeyField : NSView
@property(nonatomic, copy) void (^changed)(UINT mod, UINT vk);
- (void)setText:(NSString *)text;
@end

@implementation HotkeyField {
    NSString *_text;
    BOOL _recording;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)setText:(NSString *)text
{
    _text = [text copy];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)r
{
    (void)r;
    [[NSColor colorWithCalibratedWhite:0.94 alpha:1] setFill];
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:6 yRadius:6];
    [p fill];
    [[NSColor colorWithCalibratedWhite:0.72 alpha:1] setStroke];
    [p stroke];
    NSString *t = _recording ? tr(@"press the keys…", @"按下组合键…") : (_text ?: @"");
    NSDictionary *attrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName : _recording ? [NSColor colorWithCalibratedWhite:0.45 alpha:1]
                                                    : [NSColor colorWithCalibratedWhite:0.15 alpha:1],
    };
    NSSize sz = [t sizeWithAttributes:attrs];
    [t drawAtPoint:NSMakePoint((self.bounds.size.width - sz.width) / 2,
                               (self.bounds.size.height - sz.height) / 2)
        withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)e
{
    (void)e;
    _recording = YES;
    [self.window makeFirstResponder:self];
    [self setNeedsDisplay:YES];
}

- (BOOL)resignFirstResponder
{
    _recording = NO;
    [self setNeedsDisplay:YES];
    return YES;
}

- (void)keyDown:(NSEvent *)e
{
    if (e.keyCode == 53) { /* Esc leaves recording */
        _recording = NO;
        [self.window makeFirstResponder:nil];
        [self setNeedsDisplay:YES];
        return;
    }
    UINT mod = 0, vk = 0;
    if (!hk_from_key_event(e.keyCode, e.modifierFlags, &mod, &vk)) {
        NSBeep();
        return;
    }
    bool fkey = vk >= VK_F1 && vk <= VK_F24;
    if (!mod && !fkey) { /* a bare letter would swallow typing everywhere */
        NSBeep();
        return;
    }
    WCHAR buf[64];
    hotkey_format(mod, vk, buf);
    [self setText:wstr(buf)];
    _recording = NO;
    if (self.changed)
        self.changed(mod, vk);
}
@end

/* ---- the controller ----------------------------------------------------------------------- */

@interface SettingsController : NSObject <NSWindowDelegate>
- (void)open;
- (void)languageChanged:(id)sender;
- (void)pinTopChanged:(id)sender;
- (void)openPrivacy:(id)sender;
- (void)openRepo:(id)sender;
- (void)hotkeysChanged:(NSNotification *)n;
@end

static SettingsController *g_ctl;
static NSWindow *g_win;
static NSMutableArray *g_status;

@implementation SettingsController

- (NSTextField *)label:(NSView *)parent text:(NSString *)text rect:(NSRect)r size:(CGFloat)size dim:(bool)dim
{
    NSTextField *t = [NSTextField labelWithString:text];
    t.font = [NSFont systemFontOfSize:size];
    t.textColor = dim ? [NSColor colorWithCalibratedWhite:0.45 alpha:1]
                      : [NSColor colorWithCalibratedWhite:0.1 alpha:1];
    t.frame = r;
    [parent addSubview:t];
    return t;
}

- (NSView *)generalPage
{
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 400)];
    Config c;
    config_load(&c);

    [self label:v text:tr(@"Language", @"语言") rect:NSMakeRect(20, 340, 120, 20) size:13 dim:false];
    NSPopUpButton *pop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, 334, 280, 28) pullsDown:NO];
    [pop addItemWithTitle:tr(@"Follow the system", @"跟随系统")];
    for (int l = 0; l < LG_COUNT; l++)
        [pop addItemWithTitle:wstr(lang_name(l))];
    int choice = lang_choice();
    [pop selectItemAtIndex:choice == LG_AUTO ? 0 : choice + 1];
    pop.target = self;
    pop.action = @selector(languageChanged:);
    [v addSubview:pop];

    NSButton *top = [NSButton checkboxWithTitle:tr(@"Keep the pins above other windows", @"贴图始终置顶")
                                         target:self
                                         action:@selector(pinTopChanged:)];
    top.frame = NSMakeRect(20, 290, 400, 22);
    top.state = c.pin_top ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:top];

    [self label:v
             text:tr(@"Changes take effect immediately.", @"改动立即生效。")
             rect:NSMakeRect(20, 250, 400, 20)
             size:12
              dim:true];
    return v;
}

- (NSView *)capturePage
{
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 400)];
    [self label:v text:tr(@"Screen Recording", @"屏幕录制") rect:NSMakeRect(20, 340, 120, 20) size:13 dim:false];
    bool ok = CGPreflightScreenCaptureAccess() != 0;
    NSTextField *state = [self label:v
                                text:ok ? tr(@"granted", @"已授权") : tr(@"not granted yet", @"尚未授权")
                                rect:NSMakeRect(150, 340, 200, 20)
                                size:13
                                 dim:false];
    state.textColor = ok ? [NSColor colorWithSRGBRed:0.1 green:0.6 blue:0.2 alpha:1]
                         : [NSColor colorWithSRGBRed:0.75 green:0.15 blue:0.1 alpha:1];

    NSButton *open = [NSButton buttonWithTitle:tr(@"Open System Settings", @"打开系统设置")
                                        target:self
                                        action:@selector(openPrivacy:)];
    open.frame = NSMakeRect(20, 292, 190, 30);
    open.bezelStyle = NSBezelStyleRounded;
    [v addSubview:open];

    [self label:v
             text:tr(@"After allowing it, quit and start sniplite again (macOS applies it on launch).",
                     @"授权后请退出并重新打开 sniplite（macOS 只在启动时应用该权限）。")
             rect:NSMakeRect(20, 258, 480, 20)
             size:12
              dim:true];
    [self label:v
             text:tr(@"Capture: ScreenCaptureKit, warmed up at start.", @"采集：ScreenCaptureKit，启动时预热。")
             rect:NSMakeRect(20, 224, 480, 20)
             size:12
              dim:true];
    [self label:v
             text:tr(@"A long screenshot reads its region a few times a second while you scroll.",
                     @"长截图会每秒数次重新读取所选区域。")
             rect:NSMakeRect(20, 200, 480, 20)
             size:12
              dim:true];
    return v;
}

- (NSView *)hotkeysPage
{
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 400)];
    Config c;
    config_load(&c);
    g_status = [NSMutableArray array];
    const int names[HK_COUNT] = {0, S_ST_HK_CAPTURE, S_ST_HK_PIN, S_ST_HK_TOGGLE, S_ST_HK_OCR, S_ST_HK_OCRCOPY};
    CGFloat y = 340;
    for (int id = 1; id < HK_COUNT; id++) {
        if (id == HK_OCR || id == HK_OCRCOPY)
            continue; /* the text recognition module is not part of the port yet */
        [self label:v text:wstr(g_tr[names[id]]) rect:NSMakeRect(20, y, 150, 20) size:13 dim:false];
        HotkeyField *f = [[HotkeyField alloc] initWithFrame:NSMakeRect(180, y - 6, 220, 30)];
        WCHAR buf[64];
        hotkey_format(c.mod[id], c.vk[id], buf);
        [f setText:wstr(buf)];
        int which = id;
        __weak HotkeyField *wf = f;
        f.changed = ^(UINT mod, UINT vk) {
          Config cc;
          config_load(&cc);
          int other = config_hotkey_duplicate(&cc, which, mod, vk);
          if (other) {
              /* refuse before writing: two actions on one combination would make one
               * of them unreachable */
              NSBeep();
              WCHAR cur[64];
              hotkey_format(cc.mod[which], cc.vk[which], cur);
              [wf setText:wstr(cur)];
              NSTextField *st = g_status[which - 1];
              st.stringValue = tr(@"already used", @"已被占用");
              st.textColor = [NSColor colorWithSRGBRed:0.75 green:0.15 blue:0.1 alpha:1];
              return;
          }
          cc.mod[which] = mod;
          cc.vk[which] = vk;
          apply_config(&cc);
        };
        [v addSubview:f];
        NSTextField *st = label_plain(v, @"", NSMakeRect(414, y, 90, 20));
        [g_status addObject:st];
        y -= 44;
    }
    label_note(v,
               tr(@"Click a field and press a combination; Esc cancels. A red field means the system refused it.",
                  @"点击输入框后按下组合键；Esc 取消。红色表示系统拒绝了这组快捷键。"),
               NSMakeRect(20, 190, 480, 40));
    return v;
}

- (NSView *)aboutPage
{
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 400)];
    [self label:v
             text:[NSString stringWithFormat:@"sniplite %@", wstr(SNIPLITE_VERSION)]
             rect:NSMakeRect(20, 326, 400, 24)
             size:16
              dim:false];
    [self label:v text:wstr(T(TAGLINE)) rect:NSMakeRect(20, 298, 470, 20) size:13 dim:true];
    [self label:v
             text:@"macOS port: AppKit + CoreGraphics + ScreenCaptureKit."
             rect:NSMakeRect(20, 268, 470, 20)
             size:12
              dim:true];
    [self label:v text:@"MIT License. Original sniplite by MrTangLuyao." rect:NSMakeRect(20, 244, 470, 20) size:12 dim:true];
    NSButton *repo = [NSButton buttonWithTitle:@"github.com/MrTangLuyao/sniplite" target:self action:@selector(openRepo:)];
    repo.frame = NSMakeRect(20, 198, 330, 28);
    repo.bezelStyle = NSBezelStyleRounded;
    [v addSubview:repo];
    return v;
}

- (void)open
{
    if (g_win) {
        [g_win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }
    NSRect frame = NSMakeRect(0, 0, 560, 440);
    g_win = [[NSWindow alloc] initWithContentRect:frame
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    g_win.title = tr(@"sniplite preferences", @"sniplite 设置");
    g_win.delegate = self;
    g_win.releasedWhenClosed = NO;

    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(10, 10, 540, 420)];
    NSString *titles[4] = {tr(@"General", @"常规"), tr(@"Capture", @"截图"), tr(@"Hotkeys", @"快捷键"), tr(@"About", @"关于")};
    NSView *views[4] = {[self generalPage], [self capturePage], [self hotkeysPage], [self aboutPage]};
    for (int i = 0; i < 4; i++) {
        NSTabViewItem *it = [[NSTabViewItem alloc] initWithIdentifier:@(i)];
        it.label = titles[i];
        it.view = views[i];
        [tabs addTabViewItem:it];
    }
    g_win.contentView = tabs;
    [g_win center];
    [g_win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(hotkeysChanged:)
                                                 name:SnipHotkeysChangedNotification
                                               object:nil];
}

- (void)windowWillClose:(NSNotification *)n
{
    (void)n;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    g_status = nil;
    g_win = nil;
}

- (void)languageChanged:(id)sender
{
    NSInteger i = [(NSPopUpButton *)sender indexOfSelectedItem];
    int lang = i <= 0 ? LG_AUTO : (int)i - 1;
    Config c;
    config_load(&c);
    lang_choose(lang); /* config_save writes the choice */
    apply_config(&c);
    [g_win close];
    [self open];
}

- (void)pinTopChanged:(id)sender
{
    Config c;
    config_load(&c);
    c.pin_top = [(NSButton *)sender state] == NSControlStateValueOn;
    config_save(&c);
    pin_set_top(c.pin_top);
    [[NSNotificationCenter defaultCenter] postNotificationName:SnipConfigChangedNotification object:nil];
}

- (void)openPrivacy:(id)sender
{
    (void)sender;
    [[NSWorkspace sharedWorkspace]
        openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}

- (void)openRepo:(id)sender
{
    (void)sender;
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/MrTangLuyao/sniplite"]];
}

- (void)hotkeysChanged:(NSNotification *)n
{
    NSArray *ok = n.userInfo[@"ok"];
    if (!ok || !g_status.count)
        return;
    for (NSUInteger i = 0; i < g_status.count; i++) {
        bool good = i + 1 < ok.count && [ok[i + 1] boolValue];
        NSTextField *l = g_status[i];
        l.stringValue = good ? tr(@"registered", @"生效") : tr(@"unavailable", @"不可用");
        l.textColor = good ? [NSColor colorWithSRGBRed:0.1 green:0.6 blue:0.2 alpha:1]
                           : [NSColor colorWithSRGBRed:0.75 green:0.15 blue:0.1 alpha:1];
    }
}
@end

/* small builders outside the class, visible to every page */
static NSTextField *label_plain(NSView *v, NSString *text, NSRect r)
{
    NSTextField *t = [NSTextField labelWithString:text];
    t.font = [NSFont systemFontOfSize:12];
    t.textColor = [NSColor colorWithCalibratedWhite:0.5 alpha:1];
    t.frame = r;
    [v addSubview:t];
    return t;
}

static void label_note(NSView *v, NSString *text, NSRect r)
{
    NSTextField *t = [NSTextField wrappingLabelWithString:text];
    t.font = [NSFont systemFontOfSize:12];
    t.textColor = [NSColor colorWithCalibratedWhite:0.45 alpha:1];
    t.frame = r;
    [v addSubview:t];
}

void settings_open(void)
{
    if (!g_ctl)
        g_ctl = [SettingsController new];
    [g_ctl open];
}

bool settings_visible(void) { return g_win != nil; }