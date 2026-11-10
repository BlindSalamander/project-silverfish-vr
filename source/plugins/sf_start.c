/*
 * sf_start.dll - UEVR plugin for Project Silverfish VR: puts the profile's two start-up files right before UEVR
 * reads them, so the mod needs no launcher script and no manual step after "Import Config".
 *
 * WHY. Two things have to be true every time the game starts with this profile, and UEVR undoes both by itself:
 *
 *  1. actions.json must list the Steam Frame controller layout (bindings_frame_controller.json).
 *     UEVR has no layout for the Steam Frame controllers and writes its own actions.json over the profile's at
 *     every start (VR.cpp, initialize_openvr_input: "Writing default binding file ..."). SteamVR then converts
 *     UEVR's Quest layout for the Frame and half the buttons land in the wrong place. A read-only actions.json
 *     survives UEVR's write, so: the file gets the Frame entry if it is missing, and is made read-only.
 *
 *  2. config.txt must START with an aim method other than "Game".
 *     UEVR starts its head-tracking hook only once an aim method is active (IXRTrackingSystemHook.cpp,
 *     on_pre_engine_tick); without that hook the game never reads the VR controllers. The mod's script switches to
 *     "Game" a few seconds after the start and aims by itself - and UEVR saves whatever is set whenever its menu
 *     closes. So the file says "Game" after every session and has to be put back before the next one.
 *     Six more start settings of this profile are checked the same way (list: SF_WANT in sf_start_logic.h).
 *     Everything else in config.txt is left exactly as it is.
 *
 * WHEN. UEVR loads every plugin DLL (LoadLibrary, PluginLoader::early_init) before it reads config.txt and before it
 * writes the binding files - in UEVR's log.txt the plugins are loaded about three seconds before "Writing default
 * binding file actions.json". So the work is done in DllMain, with plain kernel32 file calls only.
 *
 * WHERE. Only inside the profile folder this DLL sits in (<profile>\plugins\sf_start.dll -> <profile>), and only if
 * that folder is this mod's profile (it has scripts\sf_main.lua). No registry, no network, nothing outside the folder.
 *
 * TO UNDO. Delete this DLL; right-click actions.json > Properties > untick "Read-only" and delete it (UEVR writes a
 * fresh one). What was done at each start is one line in UEVR's log.txt: "[sf_start] ...".
 *
 * Build (MinGW-w64): x86_64-w64-mingw32-gcc -O2 -shared -s -I<UEVR>/include -o sf_start.dll sf_start.c
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
typedef struct lua_State lua_State;
#include "uevr/API.h"
#include "sf_start_logic.h"
#include "sf_start_actions.h"

#define SF_MAXFILE 65536
#define SF_MAXPATH 900

static char g_in[SF_MAXFILE], g_out[SF_MAXFILE + 1024];
static char g_report[400] = "[sf_start] not run";
static wchar_t g_profile[SF_MAXPATH];
static const UEVR_PluginInitializeParam* g_param = NULL;

static int join(wchar_t* dst, const wchar_t* dir, const wchar_t* name) {
    size_t a = wcslen(dir), b = wcslen(name);
    if (a + 1 + b + 1 > SF_MAXPATH) return 0;
    memcpy(dst, dir, a * sizeof(wchar_t));
    dst[a] = L'\\';
    memcpy(dst + a + 1, name, (b + 1) * sizeof(wchar_t));
    return 1;
}

static int exists(const wchar_t* path) {
    DWORD a = GetFileAttributesW(path);
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

/* whole file into buf; returns its length, -1 if it cannot be opened, -2 if it is too big */
static int read_file(const wchar_t* path, char* buf, int max) {
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD got = 0, total = 0;
    LARGE_INTEGER size;
    if (h == INVALID_HANDLE_VALUE) return -1;
    if (!GetFileSizeEx(h, &size) || size.QuadPart > max) { CloseHandle(h); return -2; }
    while (total < (DWORD)size.QuadPart) {
        if (!ReadFile(h, buf + total, (DWORD)size.QuadPart - total, &got, NULL) || got == 0) break;
        total += got;
    }
    CloseHandle(h);
    return total == (DWORD)size.QuadPart ? (int)total : -1;
}

/* written beside the target first and then moved over it, so a half-written file can never be left behind */
static int write_file(const wchar_t* path, const char* data, int len) {
    wchar_t tmp[SF_MAXPATH + 8];
    HANDLE h;
    DWORD put = 0;
    size_t n = wcslen(path);
    if (n + 7 > SF_MAXPATH) return 0;
    memcpy(tmp, path, n * sizeof(wchar_t));
    memcpy(tmp + n, L".sfnew", 7 * sizeof(wchar_t));
    h = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    if (!WriteFile(h, data, (DWORD)len, &put, NULL) || put != (DWORD)len) { CloseHandle(h); DeleteFileW(tmp); return 0; }
    CloseHandle(h);
    if (!MoveFileExW(tmp, path, MOVEFILE_REPLACE_EXISTING)) { DeleteFileW(tmp); return 0; }
    return 1;
}

static const char* do_config(void) {
    wchar_t path[SF_MAXPATH];
    int n, m, changed = 0;
    static char note[64];
    if (!join(path, g_profile, L"config.txt")) return "config.txt: path too long";
    n = read_file(path, g_in, SF_MAXFILE);
    if (n == -1) return "config.txt: none yet (UEVR makes one)";
    if (n < 0) return "config.txt: too big, left alone";
    m = sf_fix_config(g_in, n, g_out, (int)sizeof(g_out), &changed);
    if (m < 0) return "config.txt: too big, left alone";
    if (changed == 0) return "config.txt: start settings already right";
    if (!write_file(path, g_out, m)) return "config.txt: COULD NOT BE WRITTEN";
    snprintf(note, sizeof(note), "config.txt: %d start setting%s put back", changed, changed == 1 ? "" : "s");
    return note;
}

static const char* do_actions(void) {
    wchar_t path[SF_MAXPATH], frame[SF_MAXPATH];
    const char* note = "actions.json: Frame layout already listed";
    int n, r, m = 0;
    DWORD attr;
    if (!join(path, g_profile, L"actions.json") || !join(frame, g_profile, L"bindings_frame_controller.json")) return "actions.json: path too long";
    if (!exists(frame)) return "actions.json: left alone (no bindings_frame_controller.json in the profile)";
    n = read_file(path, g_in, SF_MAXFILE);
    if (n == -2) return "actions.json: too big, left alone";
    r = (n >= 0) ? sf_fix_actions(g_in, n, g_out, (int)sizeof(g_out), &m) : -1;
    if (r != 0) {
        const char* data = (r == 1) ? g_out : SF_ACTIONS_JSON;
        int len = (r == 1) ? m : (int)(sizeof(SF_ACTIONS_JSON) - 1);
        attr = GetFileAttributesW(path);
        if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_READONLY)) SetFileAttributesW(path, attr & ~FILE_ATTRIBUTE_READONLY);
        if (!write_file(path, data, len)) return "actions.json: COULD NOT BE WRITTEN";
        note = (r == 1) ? "actions.json: Frame layout added to UEVR's list" : "actions.json: written new, with the Frame layout";
    }
    attr = GetFileAttributesW(path);
    if (attr == INVALID_FILE_ATTRIBUTES) return "actions.json: missing after the write";
    if ((attr & FILE_ATTRIBUTE_READONLY) == 0) {
        if (!SetFileAttributesW(path, attr | FILE_ATTRIBUTE_READONLY)) return "actions.json: COULD NOT BE MADE READ-ONLY";
        if (r == 0) note = "actions.json: Frame layout listed, made read-only again";
    }
    return note;
}

static void run(HINSTANCE inst) {
    wchar_t me[SF_MAXPATH], probe[SF_MAXPATH];
    wchar_t* slash;
    DWORD n = GetModuleFileNameW(inst, me, SF_MAXPATH);
    const char *c, *a;
    if (n == 0 || n >= SF_MAXPATH - 1) { snprintf(g_report, sizeof(g_report), "[sf_start] nothing done: own path not readable"); return; }
    { wchar_t* w; for (w = me; *w; w++) if (*w == L'/') *w = L'\\'; }
    slash = wcsrchr(me, L'\\');
    if (slash == NULL) { snprintf(g_report, sizeof(g_report), "[sf_start] nothing done: odd path"); return; }
    *slash = 0;                                                   /* ...\plugins */
    slash = wcsrchr(me, L'\\');
    if (slash == NULL || _wcsicmp(slash + 1, L"plugins") != 0) { snprintf(g_report, sizeof(g_report), "[sf_start] nothing done: not in a profile's plugins folder"); return; }
    *slash = 0;                                                   /* the profile folder */
    memcpy(g_profile, me, (wcslen(me) + 1) * sizeof(wchar_t));
    if (!join(probe, g_profile, L"scripts\\sf_main.lua") || !exists(probe)) {
        snprintf(g_report, sizeof(g_report), "[sf_start] nothing done: this is not the Silverfish VR profile (no scripts\\sf_main.lua)");
        return;
    }
    c = do_config();
    a = do_actions();
    snprintf(g_report, sizeof(g_report), "[sf_start] v1 - %s | %s", c, a);
}

__declspec(dllexport) void uevr_plugin_required_version(UEVR_PluginVersion* version) {
    version->major = UEVR_PLUGIN_VERSION_MAJOR;
    version->minor = UEVR_PLUGIN_VERSION_MINOR;
    version->patch = UEVR_PLUGIN_VERSION_PATCH;
}

__declspec(dllexport) bool uevr_plugin_initialize(const UEVR_PluginInitializeParam* param) {
    g_param = param;
    if (param != NULL && param->functions != NULL && param->functions->log_info != NULL) param->functions->log_info("%s", g_report);
    return true;
}

/* For checking the plugin without the game:  rundll32 "<profile>\plugins\sf_start.dll",SfStartCheck
 * DllMain has done the work by the time this is called; it only writes what was done to <profile>\sf_start_check.txt. */
__declspec(dllexport) void CALLBACK SfStartCheck(HWND wnd, HINSTANCE inst, LPSTR cmd, int show) {
    wchar_t path[SF_MAXPATH];
    HANDLE h;
    DWORD put = 0;
    (void)wnd; (void)inst; (void)cmd; (void)show;
    if (g_profile[0] == 0 || !join(path, g_profile, L"sf_start_check.txt")) return;
    h = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile(h, g_report, (DWORD)strlen(g_report), &put, NULL);
    CloseHandle(h);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) run(inst);
    return TRUE;
}
