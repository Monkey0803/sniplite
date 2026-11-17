/* hotkey.c: sniplite's global hotkeys on macOS.
 *
 * The settings file keeps the Windows virtual-key numbers (config.c's hotkey_parse),
 * so this file only has to translate them: VK_* and ASCII -> Carbon key codes, and
 * MOD_CONTROL/ALT/SHIFT/WIN -> controlKey/optionKey/shiftKey/cmdKey. A key Windows has
 * and macOS does not (Print Screen, Pause, Scroll Lock) registers as failed, which the
 * preferences window already shows as a red cross.
 *
 * Carbon is used rather than a CGEventTap: RegisterEventHotKey needs no Accessibility
 * permission and keeps working while another application is in front, which is what a
 * screenshot tool must have. */
#include <Carbon/Carbon.h>
#include <stdio.h>

/* NSEvent's modifier bits (NSEvent.h), repeated here because this file is plain C. */
#define SNIP_FLAG_SHIFT (1ul << 17)
#define SNIP_FLAG_CONTROL (1ul << 18)
#define SNIP_FLAG_OPTION (1ul << 19)
#define SNIP_FLAG_COMMAND (1ul << 20)

#include "hotkey.h"

#define HK_SIG 'SNPL'

static EventHotKeyRef g_ref[HK_COUNT];
static bool g_live[HK_COUNT];
static void (*g_cb)(int);
static EventHandlerRef g_handler;

typedef struct {
    UINT vk;
    UInt32 code;
    bool valid;
} VkMap;

/* kVK_ANSI_A is not kVK_ANSI_B + 1, so these are tables and not arithmetic. */
static const UInt32 kLetter[26] = {
    kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
    kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
    kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
    kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
};
static const UInt32 kDigit[10] = {kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                  kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9};
static const UInt32 kKeypad[10] = {kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2,
                                   kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                                   kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8,
                                   kVK_ANSI_Keypad9};
static const UInt32 kFunc[20] = {kVK_F1,  kVK_F2,  kVK_F3,  kVK_F4,  kVK_F5,  kVK_F6,  kVK_F7,
                                 kVK_F8,  kVK_F9,  kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14,
                                 kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20};

static bool vk_to_code(UINT vk, UInt32 *out)
{
    if (vk >= 'A' && vk <= 'Z') {
        *out = kLetter[vk - 'A'];
        return true;
    }
    if (vk >= '0' && vk <= '9') {
        *out = kDigit[vk - '0'];
        return true;
    }
    if (vk >= VK_F1 && vk < VK_F1 + (UINT)COUNTOF(kFunc)) {
        *out = kFunc[vk - VK_F1];
        return true;
    }
    if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9) {
        *out = kKeypad[vk - VK_NUMPAD0];
        return true;
    }
    switch (vk) {
    case VK_SPACE: *out = kVK_Space; return true;
    case VK_TAB: *out = kVK_Tab; return true;
    case VK_LEFT: *out = kVK_LeftArrow; return true;
    case VK_RIGHT: *out = kVK_RightArrow; return true;
    case VK_UP: *out = kVK_UpArrow; return true;
    case VK_DOWN: *out = kVK_DownArrow; return true;
    case VK_HOME: *out = kVK_Home; return true;
    case VK_END: *out = kVK_End; return true;
    case VK_PRIOR: *out = kVK_PageUp; return true;
    case VK_NEXT: *out = kVK_PageDown; return true;
    case VK_DELETE: *out = kVK_Delete; return true;
    case VK_INSERT: *out = kVK_Help; return true;
    case VK_OEM_3: *out = kVK_ANSI_Grave; return true;
    default: return false; /* PrtSc, Pause, Scroll Lock: nothing to press on a Mac */
    }
}

static UInt32 mod_to_carbon(UINT mod)
{
    UInt32 m = 0;
    if (mod & MOD_CONTROL) m |= controlKey;
    if (mod & MOD_ALT) m |= optionKey;
    if (mod & MOD_SHIFT) m |= shiftKey;
    if (mod & MOD_WIN) m |= cmdKey;
    return m;
}

static OSStatus on_hotkey(EventHandlerCallRef call, EventRef ev, void *ud)
{
    (void)call;
    (void)ud;
    EventHotKeyID id;
    if (GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof id, NULL, &id) == noErr &&
        id.signature == HK_SIG && g_cb)
        g_cb((int)id.id);
    return noErr;
}

void hk_init(void (*cb)(int id))
{
    g_cb = cb;
    if (g_handler)
        return;
    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(&on_hotkey, 1, &spec, NULL, &g_handler);
}

/* The inverse of vk_to_code, for the preferences window: a key event becomes the
 * numbers config.c's hotkey_format turns back into "Ctrl+Alt+1". */
bool hk_from_key_event(unsigned short keyCode, unsigned long flags, UINT *mod, UINT *vk)
{
    *mod = 0;
    if (flags & SNIP_FLAG_CONTROL)
        *mod |= MOD_CONTROL;
    if (flags & SNIP_FLAG_OPTION)
        *mod |= MOD_ALT;
    if (flags & SNIP_FLAG_SHIFT)
        *mod |= MOD_SHIFT;
    if (flags & SNIP_FLAG_COMMAND)
        *mod |= MOD_WIN;

    for (UINT v = 'A'; v <= 'Z'; v++) {
        UInt32 code;
        if (vk_to_code(v, &code) && code == keyCode) {
            *vk = v;
            return true;
        }
    }
    for (UINT v = '0'; v <= '9'; v++) {
        UInt32 code;
        if (vk_to_code(v, &code) && code == keyCode) {
            *vk = v;
            return true;
        }
    }
    for (UINT v = VK_F1; v < VK_F1 + (UINT)COUNTOF(kFunc); v++) {
        UInt32 code;
        if (vk_to_code(v, &code) && code == keyCode) {
            *vk = v;
            return true;
        }
    }
    static const UINT kSpecial[] = {VK_SPACE, VK_TAB, VK_LEFT, VK_RIGHT, VK_UP, VK_DOWN, VK_HOME, VK_END,
                                    VK_PRIOR, VK_NEXT, VK_DELETE, VK_INSERT, VK_OEM_3};
    for (size_t i = 0; i < COUNTOF(kSpecial); i++) {
        UInt32 code;
        if (vk_to_code(kSpecial[i], &code) && code == keyCode) {
            *vk = kSpecial[i];
            return true;
        }
    }
    return false;
}

void hk_release(void)
{
    for (int i = 0; i < HK_COUNT; i++) {
        if (g_live[i])
            UnregisterEventHotKey(g_ref[i]);
        g_ref[i] = NULL;
        g_live[i] = false;
    }
}

void hk_apply(const Config *c, bool ok[HK_COUNT])
{
    hk_release();
    for (int id = 1; id < HK_COUNT; id++) {
        ok[id] = false;
        if (!c->vk[id])
            continue; /* "none" */
        if (id == HK_OCR || id == HK_OCRCOPY)
            continue; /* the text recognition module is not part of Phase 1 */
        UInt32 code;
        if (!vk_to_code(c->vk[id], &code))
            continue;
        EventHotKeyID hid = {HK_SIG, (UInt32)id};
        EventHotKeyRef ref = NULL;
        if (RegisterEventHotKey(code, mod_to_carbon(c->mod[id]), hid, GetApplicationEventTarget(), 0, &ref) == noErr) {
            g_ref[id] = ref;
            g_live[id] = true;
            ok[id] = true;
        }
    }
}
