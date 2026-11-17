/* core_test.m: unit tests of the shared C the port reuses (lang.c, config.c, util.c)
 * plus the macOS compatibility layer.
 *
 *   ./mac/build.sh test
 *
 * HOME is pointed at a temporary directory so the settings round trip never touches the
 * real ~/Library/Application Support/sniplite/sniplite.ini. */
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "config.h"
#include "hotkey.h"
#include "lang.h"
#include "plat.h"

static int g_fail, g_pass;

#define CHECK(cond)                                                                  \
    do {                                                                             \
        if (cond) {                                                                  \
            g_pass++;                                                                \
        } else {                                                                     \
            g_fail++;                                                                \
            printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);                    \
        }                                                                            \
    } while (0)

static void test_hotkeys(void)
{
    UINT mod, vk;

    CHECK(hotkey_parse(L"Ctrl+Alt+A", &mod, &vk));
    CHECK(mod == (MOD_CONTROL | MOD_ALT));
    CHECK(vk == 'A');

    CHECK(hotkey_parse(L"shift+f3", &mod, &vk));
    CHECK(mod == MOD_SHIFT);
    CHECK(vk == VK_F1 + 2);

    CHECK(hotkey_parse(L"none", &mod, &vk));
    CHECK(mod == 0 && vk == 0);

    CHECK(!hotkey_parse(L"Ctrl+", &mod, &vk));
    CHECK(!hotkey_parse(L"A+B", &mod, &vk));
    CHECK(!hotkey_parse(L"Hyper+A", &mod, &vk));

    WCHAR out[64];
    hotkey_parse(L"Ctrl+Alt+Shift+Win+7", &mod, &vk);
    hotkey_format(mod, vk, out);
    CHECK(wcscmp(out, L"Ctrl+Alt+Shift+Win+7") == 0);

    hotkey_format(0, 0, out);
    CHECK(wcscmp(out, L"none") == 0);
}

/* The preferences window's recorder: an AppKit key event back to the config's names. */
static void test_key_events(void)
{
    UINT mod = 0, vk = 0;
    CHECK(hk_from_key_event(0x00, (1ul << 18) | (1ul << 19), &mod, &vk)); /* A, Ctrl+Alt */
    CHECK(mod == (MOD_CONTROL | MOD_ALT) && vk == 'A');

    CHECK(hk_from_key_event(0x12, 0, &mod, &vk)); /* 1 */
    CHECK(mod == 0 && vk == '1');

    CHECK(hk_from_key_event(0x7A, 0, &mod, &vk)); /* F1 */
    CHECK(vk == VK_F1);

    CHECK(hk_from_key_event(0x7B, 0, &mod, &vk)); /* left arrow */
    CHECK(vk == VK_LEFT);

    CHECK(hk_from_key_event(0x32, 0, &mod, &vk)); /* the key left of 1 */
    CHECK(vk == VK_OEM_3);

    CHECK(!hk_from_key_event(0x24, 0, &mod, &vk)); /* Return is not a hotkey key */

    /* and the names round-trip through config.c's formatter */
    WCHAR out[64];
    hk_from_key_event(0x06, (1ul << 18) | (1ul << 17), &mod, &vk); /* Z, Ctrl+Shift */
    hotkey_format(mod, vk, out);
    CHECK(wcscmp(out, L"Ctrl+Shift+Z") == 0);
}

/* The preferences window refuses a combination another action already uses. */
static void test_duplicate_hotkeys(void)
{
    Config c = {0};
    c.mod[HK_CAPTURE] = MOD_CONTROL | MOD_ALT;
    c.vk[HK_CAPTURE] = '1';
    c.mod[HK_PIN] = MOD_CONTROL | MOD_ALT;
    c.vk[HK_PIN] = '2';
    c.mod[HK_OCR] = MOD_CONTROL | MOD_ALT; /* the port has no OCR hotkeys */
    c.vk[HK_OCR] = '3';

    CHECK(config_hotkey_duplicate(&c, HK_PIN, c.mod[HK_CAPTURE], c.vk[HK_CAPTURE]) == HK_CAPTURE);
    CHECK(config_hotkey_duplicate(&c, HK_CAPTURE, c.mod[HK_CAPTURE], c.vk[HK_CAPTURE]) == 0);
    CHECK(config_hotkey_duplicate(&c, HK_TOGGLE, c.mod[HK_CAPTURE], c.vk[HK_CAPTURE]) == HK_CAPTURE);
    CHECK(config_hotkey_duplicate(&c, HK_TOGGLE, MOD_CONTROL | MOD_ALT, '3') == 0);
    CHECK(config_hotkey_duplicate(&c, HK_TOGGLE, MOD_CONTROL, c.vk[HK_CAPTURE]) == 0);
    CHECK(config_hotkey_duplicate(&c, HK_TOGGLE, MOD_CONTROL | MOD_ALT, 0) == 0);
}

static void test_rects(void)
{
    RECT r = rect_corners((POINT){20, 30}, (POINT){10, 5});
    CHECK(r.left == 10 && r.top == 5 && r.right == 21 && r.bottom == 31);

    RECT u = rect_union(r, (RECT){0, 0, 0, 0});
    CHECK(rect_eq(&u, &r));

    RECT is = rect_isect(r, (RECT){15, 15, 100, 100});
    CHECK(is.left == 15 && is.top == 15 && is.right == 21 && is.bottom == 31);

    RECT empty = rect_isect(r, (RECT){100, 100, 200, 200});
    CHECK(rect_empty(&empty));

    CHECK(rect_has(&r, 10, 5) && rect_has(&r, 20, 30) && !rect_has(&r, 21, 31));
}

static void test_strings(void)
{
    Str s = {0};
    str_add(&s, L"abc");
    str_addf(&s, L" %d", 42);
    str_addf(&s, L" %06x", 0x2A);
    str_addf(&s, L" %s", L"tail");
    CHECK(wcscmp(s.p, L"abc 42 00002a tail") == 0);
    str_free(&s);

    Str j = {0};
    str_add_json(&j, L"a\"b\n");
    CHECK(wcscmp(j.p, L"\"a\\\"b\\n\"") == 0);
    str_free(&j);

    /* UTF-8 <-> WCHAR, Chinese included */
    const char *u = "截图 sniplite";
    WCHAR w[64];
    int n = MultiByteToWideChar(CP_UTF8, 0, u, -1, w, COUNTOF(w));
    CHECK(n > 0);
    CHECK(wcscmp(w, L"截图 sniplite") == 0);
    char back[64];
    int m = WideCharToMultiByte(CP_UTF8, 0, w, -1, back, sizeof back, NULL, NULL);
    CHECK(m > 0 && strcmp(back, u) == 0);
}

static void test_languages(void)
{
    for (int lang = 0; lang < LG_COUNT; lang++)
        for (int s = 0; s < S_COUNT; s++) {
            const WCHAR *t = lang_text(lang, s);
            if (!t || !*t) {
                printf("FAIL empty text %d/%d\n", lang, s);
                g_fail++;
                return;
            }
        }
    g_pass++;

    lang_init(NULL);
    for (int lang = 0; lang < LG_COUNT; lang++) {
        lang_choose(lang);
        CHECK(lang_choice() == lang);
        CHECK(T(M_CAPTURE) == lang_text(lang, S_M_CAPTURE));
    }
    lang_choose(LG_AUTO);
}

static void test_config_roundtrip(void)
{
    WCHAR path[1024];
    config_path(path, COUNTOF(path));
    char *u = snip_wstr_to_utf8(path);
    NSString *p = u ? [NSString stringWithUTF8String:u] : nil;
    free(u);
    CHECK([p containsString:@"sniplite.ini"]);
    const char *h = getenv("HOME");
    NSString *home = h ? [NSString stringWithUTF8String:h] : NSHomeDirectory();
    CHECK([p hasPrefix:home]); /* HOME was redirected in main */

    Config c = {0};
    config_defaults(&c);
    CHECK(c.vk[HK_CAPTURE] == '1'); /* the macOS defaults */
    CHECK(c.mod[HK_CAPTURE] == (MOD_CONTROL | MOD_ALT));
    CHECK(c.vk[HK_TOGGLE] != 0);

    hotkey_parse(L"Ctrl+Shift+S", &c.mod[HK_CAPTURE], &c.vk[HK_CAPTURE]);
    hotkey_parse(L"none", &c.mod[HK_PIN], &c.vk[HK_PIN]);
    c.pin_top = false;
    CHECK(config_save(&c));

    Config d = {0};
    CHECK(config_load(&d));
    CHECK(d.vk[HK_CAPTURE] == 'S');
    CHECK(d.mod[HK_CAPTURE] == (MOD_CONTROL | MOD_SHIFT));
    CHECK(d.vk[HK_PIN] == 0);
    CHECK(d.pin_top == false);
    CHECK(d.tray == true);

    /* a missing file leaves the defaults in place */
    unlink([p fileSystemRepresentation]);
    Config e = {0};
    CHECK(!config_load(&e));
    CHECK(e.vk[HK_CAPTURE] == '1');
}

static void test_img(void)
{
    Img im = {0};
    CHECK(img_create(&im, 4, 3));
    CHECK(im.w == 4 && im.h == 3 && im.px);
    CHECK(im.px[0] == 0xFF000000u);
    img_destroy(&im);
    CHECK(!im.px && im.w == 0);
    CHECK(!img_create(&im, 0, 10));
}

static void test_qpc(void)
{
    double a = now_ms();
    for (volatile int i = 0; i < 100000; i++) {
    }
    double b = now_ms();
    CHECK(b >= a);
    CHECK(b - a < 5000);
}

int main(void)
{
    @autoreleasepool {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                    [NSString stringWithFormat:@"sniplite-test-%d", (int)getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:NULL];
        setenv("HOME", [tmp fileSystemRepresentation], 1);

        test_hotkeys();
        test_key_events();
        test_duplicate_hotkeys();
        test_rects();
        test_strings();
        test_languages();
        test_config_roundtrip();
        test_img();
        test_qpc();

        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
        printf("%d passed, %d failed\n", g_pass, g_fail);
    }
    return g_fail ? 1 : 0;
}
