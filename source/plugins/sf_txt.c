/*
 * sf_txt.dll - UEVR plugin for Project Silverfish VR (2026-11-09), v1 (mod v6.6.43)
 *
 * Why: UEVR's Lua can neither read nor pass the engine's text values (FText) - TextBlock:GetText() comes back empty.
 * To rewrite the game's button hints for the Steam Frame controller the script first has to SEE them. This plugin
 * reads the text values of a game object (a UMG widget) and can set a text widget's text. It converts through the
 * engine's own Blueprint functions (KismetTextLibrary.Conv_TextToString / Conv_StringToText), found by name and laid
 * out from their own parameter lists - no hard-coded engine offsets.
 *
 * Driven only by sf_main.lua:
 *     uevr.api:dispatch_custom_event("sftxt", "texts <object address hex>")
 *         -> dispatch_lua_event("sftxt", "texts" US "<Prop>" RS "<text>" US "<Prop>" RS "<text>" ...)
 *            every text value (FText property) the object's class and its parent classes declare (max 24);
 *            US = \x1f, RS = \x1e; line breaks in a text arrive as "\n" (two characters)
 *     uevr.api:dispatch_custom_event("sftxt", "set <object address hex> <new text, UTF-8, \n for a line break>")
 *         -> calls the object's own SetText(text) (TextBlock / RichTextBlock)   -> "set ok" or "err=<why>"
 * Anything unexpected -> "err=<why>" and nothing is touched.
 * Safety: objects are checked with UEVR's object table, memory ranges with VirtualQuery, sizes are bounded; runs on the
 * game thread (inside the script's own event). The few bytes of text the engine hands back per call are not freed
 * (the script asks at most a few hundred times per session).
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <stdint.h>
typedef struct lua_State lua_State;
#include "uevr/API.h"

static const UEVR_PluginInitializeParam* P = NULL;
static const UEVR_SDKData* SDK = NULL;

#define MAXP 256
typedef struct { wchar_t* data; int32_t num; int32_t max; } FStr;

static int g_ready = 0;                 /* 0 = not tried, 1 = ok, -1 = failed (stays off) */
static char g_why[96] = "";
static UEVR_UObjectHandle g_cdo = NULL;
static UEVR_UFunctionHandle g_t2s = NULL, g_s2t = NULL;
static int g_tsz = 0;                   /* size of a text value in this engine build (16 or 24) */
static int g_t2s_in = -1, g_t2s_ret = -1, g_t2s_size = 0;
static int g_s2t_in = -1, g_s2t_ret = -1, g_s2t_size = 0;

static void logi(const char* s) { if (P && P->functions && P->functions->log_info) P->functions->log_info("%s", s); }

static int readable(const void* p, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    const char* a = (const char*)p;
    const char* end = a + n;
    if (p == NULL || n == 0 || n > (1u << 20)) return 0;
    while (a < end) {
        if (VirtualQuery(a, &mbi, sizeof(mbi)) == 0) return 0;
        if (mbi.State != MEM_COMMIT) return 0;
        if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
        if (!(mbi.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ |
                             PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) return 0;
        a = (const char*)mbi.BaseAddress + mbi.RegionSize;
    }
    return 1;
}

static void fname_str(UEVR_FNameHandle fn, char* out, int outsz) {
    wchar_t w[256];
    unsigned int n;
    int i;
    out[0] = 0;
    if (fn == NULL || !readable(fn, 8)) return;
    n = SDK->fname->to_string(fn, w, 255);
    if (n > 255) n = 255;
    w[n] = 0;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, out, outsz, NULL, NULL);
    out[outsz - 1] = 0;
    for (i = 0; out[i]; i++) if ((unsigned char)out[i] < 0x20) out[i] = '_';
}

static void field_class(UEVR_FFieldHandle f, char* out, int outsz) {
    UEVR_FFieldClassHandle c = SDK->ffield->get_class(f);
    out[0] = 0;
    if (c == NULL) return;
    fname_str(SDK->ffield_class->get_fname(c), out, outsz);
}

static int obj_ok(void* o) { return o != NULL && SDK->uobject_hook->exists((UEVR_UObjectHandle)o); }

/* the parameter layout of a one-in / one-out Blueprint function, from its own parameter list */
static int fn_layout(UEVR_UFunctionHandle fn, const char* in_type, const char* ret_type, int* in_off, int* ret_off, int* size) {
    UEVR_FFieldHandle f;
    int n = 0;
    *in_off = -1; *ret_off = -1; *size = 0;
    if (fn == NULL) return 0;
    for (f = SDK->ustruct->get_child_properties((UEVR_UStructHandle)fn); f != NULL && n < 8; f = SDK->ffield->get_next(f), n++) {
        char cls[48];
        int off = SDK->fproperty->get_offset((UEVR_FPropertyHandle)f);
        field_class(f, cls, sizeof(cls));
        if (SDK->fproperty->is_return_param((UEVR_FPropertyHandle)f)) {
            if (ret_type == NULL || strcmp(cls, ret_type) != 0) return 0;
            *ret_off = off;
        } else if (*in_off < 0) {
            if (strcmp(cls, in_type) != 0) return 0;
            *in_off = off;
        } else return 0;                                         /* more inputs than expected */
    }
    *size = SDK->ustruct->get_properties_size((UEVR_UStructHandle)fn);
    if (*in_off < 0 || *size <= 0 || *size > MAXP || *in_off >= *size) return 0;
    if (ret_type != NULL && (*ret_off < 0 || *ret_off >= *size)) return 0;
    return 1;
}

static int setup(void) {
    UEVR_UObjectHandle cls;
    if (g_ready != 0) return g_ready > 0;
    g_ready = -1;
    cls = SDK->uobject_array->find_uobject(L"Class /Script/Engine.KismetTextLibrary");
    if (cls == NULL) { snprintf(g_why, sizeof(g_why), "no KismetTextLibrary"); return 0; }
    g_cdo = SDK->uclass->get_class_default_object((UEVR_UClassHandle)cls);
    g_t2s = SDK->ustruct->find_function((UEVR_UStructHandle)cls, L"Conv_TextToString");
    g_s2t = SDK->ustruct->find_function((UEVR_UStructHandle)cls, L"Conv_StringToText");
    if (g_cdo == NULL || g_t2s == NULL || g_s2t == NULL) { snprintf(g_why, sizeof(g_why), "text functions not found"); return 0; }
    if (!fn_layout(g_t2s, "TextProperty", "StrProperty", &g_t2s_in, &g_t2s_ret, &g_t2s_size)) { snprintf(g_why, sizeof(g_why), "TextToString layout"); return 0; }
    if (!fn_layout(g_s2t, "StrProperty", "TextProperty", &g_s2t_in, &g_s2t_ret, &g_s2t_size)) { snprintf(g_why, sizeof(g_why), "StringToText layout"); return 0; }
    g_tsz = g_t2s_ret - g_t2s_in;                                /* InText is followed by the returned string */
    if (g_tsz != 16 && g_tsz != 24) { snprintf(g_why, sizeof(g_why), "text size %d", g_tsz); return 0; }
    if (g_t2s_ret + (int)sizeof(FStr) > g_t2s_size || g_s2t_in + (int)sizeof(FStr) > g_s2t_ret || g_s2t_ret + g_tsz > g_s2t_size) {
        snprintf(g_why, sizeof(g_why), "layout bounds"); return 0;
    }
    g_ready = 1;
    {
        char line[160];
        snprintf(line, sizeof(line), "[sf_txt] ready: a text value is %d bytes here (TextToString %d/%d/%d, StringToText %d/%d/%d)",
            g_tsz, g_t2s_in, g_t2s_ret, g_t2s_size, g_s2t_in, g_s2t_ret, g_s2t_size);
        logi(line);
    }
    return 1;
}

/* one text value -> UTF-8 (line breaks as the two characters \n; control characters dropped) */
static void text_of(const void* ftext, char* out, int outsz) {
    uint8_t params[MAXP];
    wchar_t w[1024];
    char raw[3200];
    FStr* r;
    int n, i, j;
    out[0] = 0;
    if (!readable(ftext, (size_t)g_tsz)) { snprintf(out, outsz, "?"); return; }
    {
        void* td = *(void* const*)ftext;                        /* the text's data object: never null in a live text */
        if (td == NULL || !readable(td, 8)) return;
    }
    memset(params, 0, sizeof(params));
    memcpy(params + g_t2s_in, ftext, (size_t)g_tsz);
    SDK->uobject->process_event(g_cdo, g_t2s, params);
    r = (FStr*)(params + g_t2s_ret);
    if (r->data == NULL || r->num <= 1) return;
    n = r->num;
    if (n > 1000) n = 1000;
    if (!readable(r->data, (size_t)n * sizeof(wchar_t))) { snprintf(out, outsz, "?"); return; }
    memcpy(w, r->data, (size_t)n * sizeof(wchar_t));
    w[n < 1023 ? n : 1023] = 0;
    raw[0] = 0;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, raw, sizeof(raw), NULL, NULL);
    raw[sizeof(raw) - 1] = 0;
    for (i = 0, j = 0; raw[i] && j < outsz - 3; i++) {
        unsigned char c = (unsigned char)raw[i];
        if (c == '\n') { out[j++] = '\\'; out[j++] = 'n'; }
        else if (c < 0x20) { /* drop */ }
        else out[j++] = (char)c;
    }
    out[j] = 0;
}

static void do_texts(void* obj, char* out, size_t cap) {
    UEVR_UStructHandle k;
    int depth = 0, count = 0;
    size_t l;
    snprintf(out, cap, "texts");
    if (!obj_ok(obj)) { snprintf(out, cap, "err=object"); return; }
    for (k = (UEVR_UStructHandle)SDK->uobject->get_class((UEVR_UObjectHandle)obj); k != NULL && depth < 12; k = SDK->ustruct->get_super_struct(k), depth++) {
        UEVR_FFieldHandle f;
        int guard = 0;
        for (f = SDK->ustruct->get_child_properties(k); f != NULL && guard < 600 && count < 24; f = SDK->ffield->get_next(f), guard++) {
            char cls[48], nm[96], txt[2100];
            int off;
            field_class(f, cls, sizeof(cls));
            if (strcmp(cls, "TextProperty") != 0) continue;
            off = SDK->fproperty->get_offset((UEVR_FPropertyHandle)f);
            if (off <= 0 || off > (1 << 20)) continue;
            fname_str(SDK->ffield->get_fname(f), nm, sizeof(nm));
            text_of((const char*)obj + off, txt, sizeof(txt));
            l = strlen(out);
            if (l + strlen(nm) + strlen(txt) + 4 >= cap) return;
            snprintf(out + l, cap - l, "\x1f%s\x1e%s", nm, txt);
            count++;
        }
    }
}

static void do_set(void* obj, const char* utf8, char* out, size_t cap) {
    static wchar_t w[512];
    uint8_t p1[MAXP], p2[MAXP];
    UEVR_UFunctionHandle fn;
    int in_off, ret_off, size, n, i, j;
    FStr s;
    if (!obj_ok(obj)) { snprintf(out, cap, "err=object"); return; }
    n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, 500);
    if (n <= 1) { snprintf(out, cap, "err=empty"); return; }
    for (i = 0, j = 0; w[i]; i++) {                              /* "\n" (two characters) -> a line break */
        if (w[i] == L'\\' && w[i + 1] == L'n') { w[j++] = L'\n'; i++; }
        else w[j++] = w[i];
    }
    w[j] = 0;
    fn = SDK->ustruct->find_function((UEVR_UStructHandle)SDK->uobject->get_class((UEVR_UObjectHandle)obj), L"SetText");
    if (fn == NULL) { snprintf(out, cap, "err=no SetText"); return; }
    if (!fn_layout(fn, "TextProperty", NULL, &in_off, &ret_off, &size) || ret_off >= 0 || in_off + g_tsz > size) { snprintf(out, cap, "err=SetText layout"); return; }
    memset(p1, 0, sizeof(p1));
    s.data = w; s.num = j + 1; s.max = j + 1;
    memcpy(p1 + g_s2t_in, &s, sizeof(s));
    SDK->uobject->process_event(g_cdo, g_s2t, p1);
    if (*(void**)(p1 + g_s2t_ret) == NULL) { snprintf(out, cap, "err=no text made"); return; }
    memset(p2, 0, sizeof(p2));
    memcpy(p2 + in_off, p1 + g_s2t_ret, (size_t)g_tsz);
    SDK->uobject->process_event((UEVR_UObjectHandle)obj, fn, p2);
    snprintf(out, cap, "set ok");
}

static void on_custom_event(const char* evt, const char* data) {
    static char out[16384];
    char cmd[16] = {0};
    unsigned long long a = 0;
    int used = 0;
    if (evt == NULL || data == NULL || strcmp(evt, "sftxt") != 0) return;
    out[0] = 0;
    if (sscanf(data, "%15s %llx%n", cmd, &a, &used) < 2 || a == 0) snprintf(out, sizeof(out), "err=bad request");
    else if (!setup()) snprintf(out, sizeof(out), "err=not ready (%s)", g_why);
    else if (strcmp(cmd, "texts") == 0) do_texts((void*)(uintptr_t)a, out, sizeof(out));
    else if (strcmp(cmd, "set") == 0) {
        const char* t = data + used;
        while (*t == ' ') t++;
        if (strlen(t) == 0 || strlen(t) > 1200) snprintf(out, sizeof(out), "err=text length");
        else do_set((void*)(uintptr_t)a, t, out, sizeof(out));
    }
    else snprintf(out, sizeof(out), "err=unknown command");
    if (P && P->functions && P->functions->dispatch_lua_event) P->functions->dispatch_lua_event("sftxt", out);
}

__declspec(dllexport) void uevr_plugin_required_version(UEVR_PluginVersion* version) {
    version->major = UEVR_PLUGIN_VERSION_MAJOR;
    version->minor = UEVR_PLUGIN_VERSION_MINOR;
    version->patch = UEVR_PLUGIN_VERSION_PATCH;
}

__declspec(dllexport) bool uevr_plugin_initialize(const UEVR_PluginInitializeParam* param) {
    P = param;
    SDK = param->sdk;
    if (SDK == NULL || SDK->uobject == NULL || SDK->ustruct == NULL || SDK->ffield == NULL || SDK->fproperty == NULL ||
        SDK->uclass == NULL || SDK->uobject_array == NULL || SDK->fname == NULL || SDK->ffield_class == NULL ||
        SDK->uobject_hook == NULL || SDK->fproperty->is_return_param == NULL || SDK->ustruct->find_function == NULL ||
        SDK->ustruct->get_super_struct == NULL) {
        logi("[sf_txt] not started: this UEVR build lacks part of the C API");
        return true;
    }
    if (param->callbacks != NULL && param->callbacks->on_custom_event != NULL) param->callbacks->on_custom_event(on_custom_event);
    logi("[sf_txt] loaded - reads the game's hint texts for the Silverfish VR script (v1)");
    return true;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) { (void)inst; (void)reason; (void)reserved; return TRUE; }
