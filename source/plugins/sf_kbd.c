/*
 * sf_kbd.dll - SteamVR's floating keyboard for Project Silverfish VR terminals and text boxes (2026-11-07)
 *
 * Why: terminals (fnc, "L-01 false", off/close, passwords), journal notes and names need typing. The game itself only
 * reads a real keyboard. This plugin asks SteamVR (which UEVR already runs on - openvr_api.dll is already loaded in the
 * game) to show its own VR keyboard, and turns every key you hit on it into the same key press a desktop keyboard makes
 * (virtual key + scan code, so both the game's key events and its text boxes see it). Nothing is downloaded or installed.
 *
 * Driven by sf_main.lua:
 *     dispatch_custom_event("sfkbd", "show <max chars> <title>")   -- keyboard up (in front of you, chest height)
 *     dispatch_custom_event("sfkbd", "hide")
 * Answers with dispatch_lua_event("sfkbd", "shown" | "done <n>" | "closed <n>" | "err <text>")  (n = keys typed)
 * The keyboard belongs to a tiny invisible overlay of our own, so its events come to us and not into UEVR's queue.
 *
 * v2 (v6.6.14): whole-view FADE through SteamVR's compositor (used for level transitions instead of the loading box):
 *     dispatch_custom_event("sfkbd", "fade <seconds> <alpha 0-1>")   -- 1 = black, 0 = back to the game
 * The compositor keeps fading even while the game is frozen loading. Safety: a black fade that isn't renewed
 * ("fade ... 1" again) within 25 s is undone by the plugin itself, and "fade" with alpha 0 always clears it.
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#undef EXTERN_C
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-variable"
#include "openvr_capi.h"          /* first: it defines its own bool (1 byte, same as C99 bool) */
#pragma GCC diagnostic pop
typedef struct lua_State lua_State;
#include "uevr/API.h"

typedef void* (*PFN_GGI)(const char*, EVRInitError*);
static const UEVR_PluginInitializeParam* P = NULL;
static struct VR_IVROverlay_FnTable* OV = NULL;
static struct VR_IVRSystem_FnTable* SYS = NULL;
static struct VR_IVRCompositor_FnTable* COMP = NULL;
static int g_faded = 0;
static DWORD g_fade_t = 0;
static VROverlayHandle_t g_ov = 0;
static int g_ready = -1;          /* -1 not tried, 0 failed, 1 ok */
static int g_shown = 0, g_typed = 0, g_place = 1;
static float g_fwd = 0.55f, g_down = 0.40f, g_tilt = 0.61f;   /* v3: set by "place <on> <fwd cm> <down cm> <tilt deg>" */
static DWORD g_last_nl = 0;
static int g_nev = 0;
static char g_err[160];

static void logi(const char* fmt, const char* a) {
    char b[400];
    snprintf(b, sizeof(b), fmt, a ? a : "");
    if (P && P->functions && P->functions->log_info) P->functions->log_info("%s", b);
}
static void tell(const char* s) { if (P && P->functions && P->functions->dispatch_lua_event) P->functions->dispatch_lua_event("sfkbd", s); }

static int game_in_front(void) {
    HWND fg = GetForegroundWindow();
    DWORD pid = 0;
    if (fg == NULL) return 0;
    GetWindowThreadProcessId(fg, &pid);
    return pid == GetCurrentProcessId();
}

static int init_vr(void) {
    HMODULE h;
    PFN_GGI ggi;
    EVRInitError e = EVRInitError_VRInitError_None;
    char name[96];
    EVROverlayError oe;
    if (g_ready >= 0) return g_ready;
    g_ready = 0;
    h = GetModuleHandleA("openvr_api.dll");
    if (h == NULL) { snprintf(g_err, sizeof(g_err), "openvr_api.dll not loaded (UEVR not on OpenVR?)"); return 0; }
    ggi = (PFN_GGI)(void*)GetProcAddress(h, "VR_GetGenericInterface");
    if (ggi == NULL) { snprintf(g_err, sizeof(g_err), "no VR_GetGenericInterface"); return 0; }
    snprintf(name, sizeof(name), "FnTable:%s", IVROverlay_Version);
    OV = (struct VR_IVROverlay_FnTable*)ggi(name, &e);
    if (OV == NULL || e != EVRInitError_VRInitError_None) { snprintf(g_err, sizeof(g_err), "overlay interface error %d", (int)e); OV = NULL; return 0; }
    e = EVRInitError_VRInitError_None;
    snprintf(name, sizeof(name), "FnTable:%s", IVRSystem_Version);
    SYS = (struct VR_IVRSystem_FnTable*)ggi(name, &e);
    if (e != EVRInitError_VRInitError_None) SYS = NULL;          /* only needed for placing the keyboard */
    e = EVRInitError_VRInitError_None;
    snprintf(name, sizeof(name), "FnTable:%s", IVRCompositor_Version);
    COMP = (struct VR_IVRCompositor_FnTable*)ggi(name, &e);
    if (e != EVRInitError_VRInitError_None) COMP = NULL;         /* only needed for fades */
    oe = OV->FindOverlay("silverfish.vr.keyboard", &g_ov);
    if (oe != EVROverlayError_VROverlayError_None || g_ov == 0) {
        oe = OV->CreateOverlay("silverfish.vr.keyboard", "Silverfish VR keyboard", &g_ov);
        if (oe != EVROverlayError_VROverlayError_None) { snprintf(g_err, sizeof(g_err), "CreateOverlay error %d", (int)oe); g_ov = 0; return 0; }
    }
    g_ready = 1;
    logi("[sf_kbd] ready - SteamVR keyboard available%s", SYS ? "" : " (placement: SteamVR default)");
    return 1;
}

/* the keyboard g_fwd in front of you (level), g_down below your eyes, tilted up toward you by g_tilt (v3: adjustable;
   v2 was 55 cm / 40 cm / 35 deg, which covered the bottom of a terminal screen) */
static void place_keyboard(void) {
    TrackedDevicePose_t pose;
    struct HmdMatrix34_t m;
    float fx, fz, l, px, py, pz, a = g_tilt, ca, sa;
    float x[3], y[3], z[3], y2[3], z2[3];
    int i;
    if (!g_place || SYS == NULL || OV == NULL || OV->SetKeyboardTransformAbsolute == NULL) return;
    memset(&pose, 0, sizeof(pose));
    SYS->GetDeviceToAbsoluteTrackingPose(ETrackingUniverseOrigin_TrackingUniverseStanding, 0.0f, &pose, 1);
    if (!pose.bPoseIsValid) return;
    fx = -pose.mDeviceToAbsoluteTracking.m[0][2];      /* forward = -Z column */
    fz = -pose.mDeviceToAbsoluteTracking.m[2][2];
    l = sqrtf(fx * fx + fz * fz);
    if (l < 0.01f) return;
    fx /= l; fz /= l;
    px = pose.mDeviceToAbsoluteTracking.m[0][3] + fx * g_fwd;
    py = pose.mDeviceToAbsoluteTracking.m[1][3] - g_down;
    pz = pose.mDeviceToAbsoluteTracking.m[2][3] + fz * g_fwd;
    z[0] = -fx; z[1] = 0; z[2] = -fz;                  /* faces you */
    y[0] = 0; y[1] = 1; y[2] = 0;
    x[0] = y[1] * z[2] - y[2] * z[1]; x[1] = y[2] * z[0] - y[0] * z[2]; x[2] = y[0] * z[1] - y[1] * z[0];
    ca = cosf(a); sa = sinf(a);
    for (i = 0; i < 3; i++) { z2[i] = z[i] * ca + y[i] * sa; y2[i] = y[i] * ca - z[i] * sa; }
    for (i = 0; i < 3; i++) { m.m[i][0] = x[i]; m.m[i][1] = y2[i]; m.m[i][2] = z2[i]; }
    m.m[0][3] = px; m.m[1][3] = py; m.m[2][3] = pz;
    OV->SetKeyboardTransformAbsolute(ETrackingUniverseOrigin_TrackingUniverseStanding, &m);
}

static void send_vk(WORD vk, int up) {
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
static void send_unicode(WCHAR ch) {
    INPUT in[2];
    memset(in, 0, sizeof(in));
    in[0].type = in[1].type = INPUT_KEYBOARD;
    in[0].ki.wScan = in[1].ki.wScan = ch;
    in[0].ki.dwFlags = KEYEVENTF_UNICODE;
    in[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
    SendInput(2, in, sizeof(INPUT));
}
static void type_char(WCHAR ch) {
    SHORT r;
    if (ch == 8) { send_vk(VK_BACK, 0); send_vk(VK_BACK, 1); return; }
    if (ch == '\n' || ch == '\r') { send_vk(VK_RETURN, 0); send_vk(VK_RETURN, 1); g_last_nl = GetTickCount(); return; }
    if (ch < 32) return;
    r = VkKeyScanW(ch);
    if (r != -1 && (HIBYTE(r) & 6) == 0) {             /* a plain key (+ Shift): exactly like the desk keyboard */
        WORD vk = LOBYTE(r);
        int sh = (HIBYTE(r) & 1) != 0;
        if (sh) send_vk(VK_LSHIFT, 0);
        send_vk(vk, 0); send_vk(vk, 1);
        if (sh) send_vk(VK_LSHIFT, 1);
    } else send_unicode(ch);
}

static void hide_kb(void) {
    if (g_ready == 1 && g_shown && OV->HideKeyboard) OV->HideKeyboard();
    g_shown = 0;
}

static void on_custom_event(const char* evt, const char* data) {
    char cmd[16] = {0}, title[96] = "Silverfish";
    unsigned maxc = 256;
    int n;
    EVROverlayError oe;
    if (evt == NULL || data == NULL || strcmp(evt, "sfkbd") != 0) return;
    n = sscanf(data, "%15s %u %95[^\n]", cmd, &maxc, title);
    if (n < 1) return;
    if (!strcmp(cmd, "hide")) { hide_kb(); return; }
    if (!strcmp(cmd, "place")) {                                   /* place <on> [<fwd cm> <down cm> <tilt deg>] */
        float f = 0, d = 0, t = 0;
        g_place = (maxc != 0);
        if (sscanf(data, "%15s %u %f %f %f", cmd, &maxc, &f, &d, &t) == 5) {
            if (f >= 20 && f <= 120) g_fwd = f / 100.0f;
            if (d >= 0 && d <= 120) g_down = d / 100.0f;
            if (t >= 0 && t <= 80) g_tilt = t * 3.14159265f / 180.0f;
        }
        if (g_shown) place_keyboard();                             /* moves an open keyboard at once */
        return;
    }
    if (!strcmp(cmd, "fade")) {                                    /* fade <seconds> <alpha> */
        float sec = 0.3f, alpha = 0.0f;
        if (sscanf(data, "%15s %f %f", cmd, &sec, &alpha) < 3) return;
        if (!init_vr() || COMP == NULL || COMP->FadeToColor == NULL) {
            if (!g_err[0]) snprintf(g_err, sizeof(g_err), "no compositor interface");
            { char b[200]; snprintf(b, sizeof(b), "err fade: %s", g_err); tell(b); }
            return;
        }
        if (sec < 0) sec = 0;
        if (sec > 3) sec = 3;
        if (alpha < 0) alpha = 0;
        if (alpha > 1) alpha = 1;
        COMP->FadeToColor(sec, 0.0f, 0.0f, 0.0f, alpha, 0);
        g_faded = alpha > 0.01f;
        g_fade_t = GetTickCount();
        return;
    }
    if (strcmp(cmd, "show") != 0) return;
    if (!init_vr()) { char b[200]; snprintf(b, sizeof(b), "err %s", g_err); tell(b); logi("[sf_kbd] %s", g_err); return; }
    if (maxc < 8 || maxc > 1024) maxc = 256;
    oe = OV->ShowKeyboardForOverlay(g_ov, EGamepadTextInputMode_k_EGamepadTextInputModeNormal,
        EGamepadTextInputLineMode_k_EGamepadTextInputLineModeSingleLine,
        EKeyboardFlags_KeyboardFlag_Minimal | EKeyboardFlags_KeyboardFlag_Modal, title, maxc, "", 0);
    if (oe != EVROverlayError_VROverlayError_None) {
        char b[64]; snprintf(b, sizeof(b), "err ShowKeyboard %d", (int)oe); tell(b);
        snprintf(b, sizeof(b), "%d", (int)oe); logi("[sf_kbd] ShowKeyboardForOverlay error %s", b);
        return;
    }
    place_keyboard();
    g_shown = 1; g_typed = 0;
    tell("shown");
}

static void on_pre_tick(UEVR_UGameEngineHandle engine, float delta) {
    struct VREvent_t ev;
    char b[48];
    (void)engine; (void)delta;
    if (g_ready != 1 || g_ov == 0) return;
    if (g_faded && COMP != NULL && GetTickCount() - g_fade_t > 25000) {      /* never leave you in the dark */
        COMP->FadeToColor(0.5f, 0.0f, 0.0f, 0.0f, 0.0f, 0);
        g_faded = 0;
        logi("[sf_kbd] fade to black was not renewed for 25 s - faded back in%s", "");
        tell("fade watchdog");
    }
    while (OV->PollNextOverlayEvent(g_ov, &ev, sizeof(ev))) {
        if (g_nev < 12) {                                /* first few events in the UEVR log (diagnostics) */
            char t[32];
            g_nev++;
            snprintf(t, sizeof(t), "%u", (unsigned)ev.eventType);
            logi("[sf_kbd] keyboard event type %s", t);
        }
        if (ev.eventType == EVREventType_VREvent_KeyboardCharInput) {
            WCHAR w[8];
            char c[9];
            int k, nw;
            memcpy(c, ev.data.keyboard.cNewInput, 8); c[8] = 0;
            if (!game_in_front()) continue;
            nw = MultiByteToWideChar(CP_UTF8, 0, c, -1, w, 8);
            for (k = 0; k < nw - 1; k++) { type_char(w[k]); g_typed++; }
        } else if (ev.eventType == EVREventType_VREvent_KeyboardDone) {
            if (GetTickCount() - g_last_nl > 250 && game_in_front()) { send_vk(VK_RETURN, 0); send_vk(VK_RETURN, 1); }
            g_shown = 0;
            snprintf(b, sizeof(b), "done %d", g_typed); tell(b);
        } else if (ev.eventType == EVREventType_VREvent_KeyboardClosed) {
            g_shown = 0;
            snprintf(b, sizeof(b), "closed %d", g_typed); tell(b);
        }
    }
}

__declspec(dllexport) void uevr_plugin_required_version(UEVR_PluginVersion* version) {
    version->major = UEVR_PLUGIN_VERSION_MAJOR;
    version->minor = UEVR_PLUGIN_VERSION_MINOR;
    version->patch = UEVR_PLUGIN_VERSION_PATCH;
}

__declspec(dllexport) bool uevr_plugin_initialize(const UEVR_PluginInitializeParam* param) {
    P = param;
    if (param->callbacks != NULL && param->callbacks->on_custom_event != NULL) param->callbacks->on_custom_event(on_custom_event);
    if (param->sdk != NULL && param->sdk->callbacks != NULL && param->sdk->callbacks->on_pre_engine_tick != NULL)
        param->sdk->callbacks->on_pre_engine_tick(on_pre_tick);
    logi("[sf_kbd] loaded (v2) - SteamVR keyboard for terminals and text boxes + whole-view fades for level transitions%s", "");
    return true;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) { (void)inst; (void)reason; (void)reserved; return TRUE; }
