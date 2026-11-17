/* hotkey.h: the global hotkeys of the port, from the Config the shared config.c keeps.
 * Carbon's RegisterEventHotKey, so nothing here needs the Accessibility permission. */
#pragma once

#include "config.h"

/* Called on the main thread when a registered hotkey fires; id is one of HK_*. */
void hk_init(void (*cb)(int id));

/* Register what Config says. ok[id] reports, per id, whether the system took it (a
 * key with no macOS counterpart, or one another application holds, fails). Hotkeys
 * that Phase 1 does not act on yet are left unregistered so they stay free. */
void hk_apply(const Config *c, bool ok[HK_COUNT]);

void hk_release(void);

/* A key event from AppKit (keyCode and NSEventModifierFlag*) in the config's names:
 * false when the key has no VK_*. Used by the preferences window's recorder. */
bool hk_from_key_event(unsigned short keyCode, unsigned long flags, UINT *mod, UINT *vk);
