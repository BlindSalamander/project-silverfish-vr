/*
 * a_sf_hand.dll - tiny UEVR plugin for Project Silverfish VR: the triggers of a left-handed player.
 *
 * Why: the game is keyboard / mouse only. The joytokey plugin turns the pad's right trigger into the left mouse
 * button (fire) and the pad's left trigger into the right mouse button (aim), and it reads the pad before any script
 * can touch it. With the gun in the LEFT hand the two triggers have to change places before joytokey looks.
 * UEVR starts its plugins - and then calls them - in the alphabetical order of their file names. That is the only
 * reason for the "a_" in this file's name: it must come before "joytokey".
 *
 * Driven by the mod's Lua script through UEVR's custom events:
 *     uevr.api:dispatch_custom_event("sfhand", "left 1")    -- swap the two triggers in what the plugins after us see
 *     uevr.api:dispatch_custom_event("sfhand", "left 0")    -- leave them alone (this is how the plugin starts)
 * Answer, so the script can show that the plugin is there: dispatch_lua_event("sfhand", "left=1" or "left=0").
 * Nothing else is read or changed: no buttons, no sticks, no files, nothing in the game.
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
typedef struct lua_State lua_State;
#include "uevr/API.h"

/* the two structures of XInput, written out so that no SDK header is needed */
typedef struct { WORD wButtons; BYTE bLeftTrigger; BYTE bRightTrigger; SHORT sThumbLX; SHORT sThumbLY; SHORT sThumbRX; SHORT sThumbRY; } SF_PAD;
typedef struct { DWORD dwPacketNumber; SF_PAD Gamepad; } SF_PADSTATE;

static const UEVR_PluginInitializeParam* g_param = NULL;
static volatile LONG g_left = 0;
static int g_logged = 0;

static void logs(const char* text) {
    if (g_param == NULL || g_param->functions == NULL || g_param->functions->log_info == NULL) return;
    g_param->functions->log_info("%s", text);
}

static void on_custom_event(const char* evt, const char* data) {
    if (evt == NULL || data == NULL || strcmp(evt, "sfhand") != 0) return;
    char cmd[16] = {0};
    int v = 0;
    if (sscanf(data, "%15s %d", cmd, &v) < 2 || strcmp(cmd, "left") != 0) return;
    LONG want = (v != 0) ? 1 : 0;
    LONG was = InterlockedExchange(&g_left, want);
    if (was != want && g_logged < 10) {
        g_logged++;
        logs(want ? "[a_sf_hand] left-handed: the two triggers change places (left = fire, right = aim)"
                  : "[a_sf_hand] right-handed: the triggers are left as they are");
    }
    if (g_param != NULL && g_param->functions != NULL && g_param->functions->dispatch_lua_event != NULL)
        g_param->functions->dispatch_lua_event("sfhand", want ? "left=1" : "left=0");
}

static void on_pad(unsigned int* retval, unsigned int user_index, void* state) {
    (void)retval; (void)user_index;
    if (state == NULL || g_left == 0) return;
    SF_PADSTATE* s = (SF_PADSTATE*)state;
    BYTE t = s->Gamepad.bLeftTrigger;
    s->Gamepad.bLeftTrigger = s->Gamepad.bRightTrigger;
    s->Gamepad.bRightTrigger = t;
}

__declspec(dllexport) void uevr_plugin_required_version(UEVR_PluginVersion* version) {
    version->major = UEVR_PLUGIN_VERSION_MAJOR;
    version->minor = UEVR_PLUGIN_VERSION_MINOR;
    version->patch = UEVR_PLUGIN_VERSION_PATCH;
}

__declspec(dllexport) bool uevr_plugin_initialize(const UEVR_PluginInitializeParam* param) {
    g_param = param;
    if (param->callbacks != NULL && param->callbacks->on_custom_event != NULL) param->callbacks->on_custom_event(on_custom_event);
    if (param->callbacks != NULL && param->callbacks->on_xinput_get_state != NULL) param->callbacks->on_xinput_get_state(on_pad);
    logs("[a_sf_hand] loaded - trigger swap for left-handed play in the Silverfish VR script (v1, off until the script asks)");
    return true;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)inst; (void)reason; (void)reserved;
    return TRUE;
}
