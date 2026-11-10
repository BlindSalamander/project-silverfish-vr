/*
 * sf_keys.dll - tiny UEVR plugin for Project Silverfish VR (2026-11-07)
 *
 * Why: the joytokey plugin sends keys with a virtual-key code but no hardware scan code. Unreal Engine tells
 * Left Shift from Right Shift ONLY by the scan code, so a Shift sent that way is thrown away - sprint and
 * shift-click never reached the game. This plugin presses keys the way a real keyboard does (virtual key AND
 * scan code, plus the "extended" flag where a real keyboard sets it).
 *
 * It is driven by the mod's Lua script through UEVR's custom events:
 *     uevr.api:dispatch_custom_event("sfkey", "hold 0xA0")   -- keep a key down (send every frame while held)
 *     uevr.api:dispatch_custom_event("sfkey", "up 0xA0")     -- let it go now
 *     uevr.api:dispatch_custom_event("sfkey", "tap 0x20")    -- press and release (60 ms)
 *     uevr.api:dispatch_custom_event("sfkey", "releaseall")
 * Safety: a held key is released by itself if the script stops refreshing it for 0.25 s (so a script error can
 * never leave Shift stuck), and keys are only sent while the game's own window is in front.
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
typedef struct lua_State lua_State;
#include "uevr/API.h"

#define MAXK 16
typedef struct { WORD vk; int down; DWORD last; DWORD tap_until; } Key;

static const UEVR_PluginInitializeParam* g_param = NULL;
static Key g_keys[MAXK];
static int g_logged_focus = 0, g_logged_first = 0;

static void logi(const char* fmt, const char* a, unsigned v) {
    if (g_param == NULL || g_param->functions == NULL || g_param->functions->log_info == NULL) return;
    char buf[256];
    snprintf(buf, sizeof(buf), fmt, a ? a : "", v);
    g_param->functions->log_info("%s", buf);
}

static int game_in_front(void) {
    HWND fg = GetForegroundWindow();
    DWORD pid = 0;
    if (fg == NULL) return 0;
    GetWindowThreadProcessId(fg, &pid);
    return pid == GetCurrentProcessId();
}

static void send_key(WORD vk, int up) {
    INPUT in;
    UINT sc = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC_EX);
    memset(&in, 0, sizeof(in));
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = vk;
    in.ki.wScan = (WORD)(sc & 0xFF);
    in.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
    if ((sc & 0xFF00) == 0xE000 || (sc & 0xFF00) == 0xE100) in.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
    SendInput(1, &in, sizeof(INPUT));
}

static Key* find_key(WORD vk, int create) {
    int i, free_i = -1;
    for (i = 0; i < MAXK; i++) {
        if (g_keys[i].vk == vk) return &g_keys[i];
        if (g_keys[i].vk == 0 && free_i < 0) free_i = i;
    }
    if (!create || free_i < 0) return NULL;
    memset(&g_keys[free_i], 0, sizeof(Key));
    g_keys[free_i].vk = vk;
    return &g_keys[free_i];
}

static void key_release(Key* k) {
    if (k->down) send_key(k->vk, 1);
    memset(k, 0, sizeof(Key));
}

static void release_all(void) {
    int i;
    for (i = 0; i < MAXK; i++) if (g_keys[i].vk != 0) key_release(&g_keys[i]);
}

static void key_press(Key* k, DWORD now) {
    if (!k->down) {
        if (!game_in_front()) {
            if (!g_logged_focus) { g_logged_focus = 1; logi("[sf_keys] key 0x%s%02X not sent: the game window is not in front", "", k->vk); }
            return;
        }
        send_key(k->vk, 0);
        k->down = 1;
        if (g_logged_first < 12) { g_logged_first++; logi("[sf_keys] key down 0x%s%02X (with scan code)", "", k->vk); }
    }
    k->last = now;
}

static void on_custom_event(const char* evt, const char* data) {
    if (evt == NULL || data == NULL || strcmp(evt, "sfkey") != 0) return;
    DWORD now = GetTickCount();
    char cmd[16] = {0};
    unsigned v = 0;
    if (sscanf(data, "%15s %x", cmd, &v) < 1) return;
    if (strcmp(cmd, "releaseall") == 0) { release_all(); return; }
    if (v == 0 || v > 0xFE) return;
    Key* k = find_key((WORD)v, strcmp(cmd, "up") != 0);
    if (k == NULL) return;
    if (strcmp(cmd, "hold") == 0) {
        key_press(k, now);
    } else if (strcmp(cmd, "tap") == 0) {
        key_press(k, now);
        k->tap_until = now + 60;
    } else if (strcmp(cmd, "up") == 0) {
        key_release(k);
    }
}

static void on_pre_tick(UEVR_UGameEngineHandle engine, float delta) {
    (void)engine; (void)delta;
    DWORD now = GetTickCount();
    int i;
    for (i = 0; i < MAXK; i++) {
        Key* k = &g_keys[i];
        if (k->vk == 0) continue;
        if (k->tap_until != 0) {
            if (now >= k->tap_until) key_release(k);
        } else if (now - k->last > 250) {
            key_release(k);                      /* the script stopped holding it */
        }
    }
}

__declspec(dllexport) void uevr_plugin_required_version(UEVR_PluginVersion* version) {
    version->major = UEVR_PLUGIN_VERSION_MAJOR;
    version->minor = UEVR_PLUGIN_VERSION_MINOR;
    version->patch = UEVR_PLUGIN_VERSION_PATCH;
}

__declspec(dllexport) bool uevr_plugin_initialize(const UEVR_PluginInitializeParam* param) {
    g_param = param;
    memset(g_keys, 0, sizeof(g_keys));
    if (param->callbacks != NULL && param->callbacks->on_custom_event != NULL) param->callbacks->on_custom_event(on_custom_event);
    if (param->sdk != NULL && param->sdk->callbacks != NULL && param->sdk->callbacks->on_pre_engine_tick != NULL)
        param->sdk->callbacks->on_pre_engine_tick(on_pre_tick);
    logi("[sf_keys] loaded%s - keys with real scan codes for the Silverfish VR script (v%u)", "", 1);
    return true;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_DETACH) release_all();
    return TRUE;
}
