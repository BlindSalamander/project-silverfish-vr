/*
 * sf_inv.dll - tiny READ-ONLY UEVR plugin for Project Silverfish VR (2026-11-07)
 * v2 (v6.6.12): the item struct is a Blueprint struct, which has no native "struct ops", so UEVR's get_struct_size()
 *     says 0 for it (v1 stopped with "err=size 0"). The size now comes from the struct's own property layout
 *     (get_properties_size, rounded up to its alignment) - the same rule Unreal uses for Blueprint structs.
 *     Arrays of classes / objects (GameInstance EquippedItems) are read too. A second SaveGame address may be given
 *     (the player's own "Save" and the game instance's "SaveSlot_Ref" - normally the same object).
 *
 * Why: the game keeps the player's equipped items (weapon slots 1-4, utility slots 5-8) in arrays of structs
 * (GameInstance_FP_C.EquippedItems, SaveGame_BP_C.PlayerEquipment). UEVR's Lua can't read arrays of structs, so the
 * mod's D-pad weapon cycling couldn't see which slots hold a weapon. This plugin reads those arrays through UEVR's
 * C API (property offsets + struct layout from the game's own reflection data) and hands the result to the Lua
 * script as a text line. It never writes anything and never calls game functions.
 *
 * Driven only by sf_main.lua:
 *     uevr.api:dispatch_custom_event("sfinv", "read <GameInstance address hex> <SaveGame address hex>")
 * -> answers right away (same thread) with uevr dispatch_lua_event("sfinv", "<text>"):
 *     one line per array:  <ArrayName>;n=<count>;sz=<struct size>;f=<field>:<type>,...;0=<v>|<v>|...;1=...
 * Safety: objects are checked with UEVR's object table before use, every memory range is checked with VirtualQuery
 * before it is read, counts / sizes / offsets are bounded, and anything unexpected just ends that array's line.
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
static int g_logged = 0;

static void logi(const char* s) {
    if (P && P->functions && P->functions->log_info) P->functions->log_info("%s", s);
}

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

/* FName -> UTF-8, characters that would break the line format replaced by '_' */
static void fname_str(UEVR_FNameHandle fn, char* out, int outsz) {
    wchar_t w[256];
    unsigned int n;
    int i;
    out[0] = 0;
    if (fn == NULL || SDK->fname == NULL || SDK->fname->to_string == NULL) return;
    if (!readable(fn, 8)) return;
    n = SDK->fname->to_string(fn, w, 255);
    if (n > 255) n = 255;
    w[n] = 0;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, out, outsz, NULL, NULL);
    out[outsz - 1] = 0;
    for (i = 0; out[i]; i++) if (out[i] == '|' || out[i] == ';' || out[i] == '=' || out[i] == ',' || out[i] == '\n') out[i] = '_';
}

static void field_class(UEVR_FFieldHandle f, char* out, int outsz) {
    UEVR_FFieldClassHandle c = SDK->ffield->get_class(f);
    out[0] = 0;
    if (c == NULL) return;
    fname_str(SDK->ffield_class->get_fname(c), out, outsz);
}

static int obj_ok(void* o) {
    return o != NULL && SDK->uobject_hook != NULL && SDK->uobject_hook->exists((UEVR_UObjectHandle)o);
}

static void obj_name(void* o, char* out, int outsz) {
    out[0] = 0;
    if (!obj_ok(o)) { snprintf(out, outsz, "-"); return; }
    fname_str(SDK->uobject->get_fname((UEVR_UObjectHandle)o), out, outsz);
}

/* append with bound */
static void app(char* buf, size_t cap, const char* s) {
    size_t l = strlen(buf), k = strlen(s);
    if (l + k + 1 >= cap) return;
    memcpy(buf + l, s, k + 1);
}

#define MAXF 24
static void read_array(void* obj, const wchar_t* wname, const char* name, char* out, size_t cap) {
    char tmp[512], cls[64];
    UEVR_UClassHandle klass;
    UEVR_FPropertyHandle prop, inner;
    UEVR_UScriptStructHandle ss;
    UEVR_FFieldHandle f;
    UEVR_FFieldHandle fields[MAXF];
    char ftype[MAXF][48];
    int foff[MAXF];
    int nf = 0, i, j, size, count;
    const char* how = "ops";
    struct { char* data; int32_t num; int32_t max; } *arr;

    if (!obj_ok(obj)) { snprintf(tmp, sizeof(tmp), "%s;err=object\n", name); app(out, cap, tmp); return; }
    klass = SDK->uobject->get_class((UEVR_UObjectHandle)obj);
    prop = klass ? SDK->ustruct->find_property((UEVR_UStructHandle)klass, wname) : NULL;
    if (prop == NULL) { snprintf(tmp, sizeof(tmp), "%s;err=noprop\n", name); app(out, cap, tmp); return; }
    field_class((UEVR_FFieldHandle)prop, cls, sizeof(cls));
    if (strcmp(cls, "ArrayProperty") != 0) { snprintf(tmp, sizeof(tmp), "%s;err=type %s\n", name, cls); app(out, cap, tmp); return; }
    inner = SDK->farrayproperty->get_inner((UEVR_FArrayPropertyHandle)prop);
    if (inner == NULL) { snprintf(tmp, sizeof(tmp), "%s;err=noinner\n", name); app(out, cap, tmp); return; }
    field_class((UEVR_FFieldHandle)inner, cls, sizeof(cls));
    if (!strcmp(cls, "ClassProperty") || !strcmp(cls, "ObjectProperty")) {      /* v2: array of classes / objects */
        arr = SDK->uobject->get_property_data((UEVR_UObjectHandle)obj, wname);
        if (arr == NULL || !readable(arr, 16)) { snprintf(tmp, sizeof(tmp), "%s;err=array\n", name); app(out, cap, tmp); return; }
        count = arr->num;
        if (count < 0 || count > 64) { snprintf(tmp, sizeof(tmp), "%s;err=count %d\n", name, count); app(out, cap, tmp); return; }
        snprintf(tmp, sizeof(tmp), "%s;n=%d;sz=8;kind=%s", name, count, cls);
        app(out, cap, tmp);
        if (count > 0 && (arr->data == NULL || !readable(arr->data, (size_t)count * 8))) { app(out, cap, ";err=data\n"); return; }
        for (i = 0; i < count; i++) {
            char v[300];
            void* p = *(void**)(arr->data + (size_t)i * 8);
            if (p == NULL) snprintf(v, sizeof(v), "0"); else obj_name(p, v, sizeof(v));
            snprintf(tmp, sizeof(tmp), ";%d=", i);
            app(out, cap, tmp);
            app(out, cap, v);
        }
        app(out, cap, "\n");
        return;
    }
    if (strcmp(cls, "StructProperty") != 0) { snprintf(tmp, sizeof(tmp), "%s;err=inner %s\n", name, cls); app(out, cap, tmp); return; }
    ss = SDK->fstructproperty->get_struct((UEVR_FStructPropertyHandle)inner);
    size = ss ? SDK->uscriptstruct->get_struct_size(ss) : 0;
    if (size <= 0 && ss != NULL && SDK->ustruct->get_properties_size != NULL) {   /* v2: Blueprint struct */
        int ps = SDK->ustruct->get_properties_size((UEVR_UStructHandle)ss);
        int al = SDK->ustruct->get_min_alignment != NULL ? SDK->ustruct->get_min_alignment((UEVR_UStructHandle)ss) : 1;
        if (al < 1 || al > 16) al = (al > 16) ? 16 : 1;
        size = ps > 0 ? ((ps + al - 1) / al) * al : 0;
        how = "props";
    }
    arr = SDK->uobject->get_property_data((UEVR_UObjectHandle)obj, wname);
    if (size <= 0 || size > 4096 || arr == NULL || !readable(arr, 16)) { snprintf(tmp, sizeof(tmp), "%s;err=size %d\n", name, size); app(out, cap, tmp); return; }
    count = arr->num;
    if (count < 0 || count > 64) { snprintf(tmp, sizeof(tmp), "%s;err=count %d\n", name, count); app(out, cap, tmp); return; }
    snprintf(tmp, sizeof(tmp), "%s;n=%d;sz=%d;how=%s;f=", name, count, size, how);
    app(out, cap, tmp);
    for (f = SDK->ustruct->get_child_properties((UEVR_UStructHandle)ss); f != NULL && nf < MAXF; f = SDK->ffield->get_next(f)) {
        char fnm[96];
        fname_str(SDK->ffield->get_fname(f), fnm, sizeof(fnm));
        field_class(f, ftype[nf], sizeof(ftype[nf]));
        foff[nf] = SDK->fproperty->get_offset((UEVR_FPropertyHandle)f);
        if (foff[nf] < 0 || foff[nf] >= size) { app(out, cap, ";err=layout\n"); return; }   /* v2: offsets must fit */
        fields[nf] = f;
        snprintf(tmp, sizeof(tmp), "%s%s:%s@%d", nf ? "," : "", fnm, ftype[nf], foff[nf]);
        app(out, cap, tmp);
        nf++;
    }
    if (count > 0 && (arr->data == NULL || !readable(arr->data, (size_t)count * (size_t)size))) { app(out, cap, ";err=data\n"); return; }
    for (i = 0; i < count; i++) {
        char* e = arr->data + (size_t)i * (size_t)size;
        snprintf(tmp, sizeof(tmp), ";%d=", i);
        app(out, cap, tmp);
        for (j = 0; j < nf; j++) {
            const char* t = ftype[j];
            int off = foff[j];
            char v[300];
            v[0] = 0;
            if (off < 0 || off >= size) { snprintf(v, sizeof(v), "?"); }
            else if (!strcmp(t, "ObjectProperty") || !strcmp(t, "ClassProperty")) {
                void* p = (off + 8 <= size) ? *(void**)(e + off) : NULL;
                if (p == NULL) snprintf(v, sizeof(v), "0"); else obj_name(p, v, sizeof(v));
            } else if (!strcmp(t, "IntProperty")) { if (off + 4 <= size) snprintf(v, sizeof(v), "%d", *(int32_t*)(e + off)); }
            else if (!strcmp(t, "Int64Property")) { if (off + 8 <= size) snprintf(v, sizeof(v), "%lld", (long long)*(int64_t*)(e + off)); }
            else if (!strcmp(t, "ByteProperty") || !strcmp(t, "EnumProperty")) { snprintf(v, sizeof(v), "%u", (unsigned)*(uint8_t*)(e + off)); }
            else if (!strcmp(t, "FloatProperty")) { if (off + 4 <= size) snprintf(v, sizeof(v), "%g", (double)*(float*)(e + off)); }
            else if (!strcmp(t, "DoubleProperty")) { if (off + 8 <= size) snprintf(v, sizeof(v), "%g", *(double*)(e + off)); }
            else if (!strcmp(t, "BoolProperty")) {
                if (SDK->fboolproperty && SDK->fboolproperty->get_value_from_object)
                    snprintf(v, sizeof(v), "%d", SDK->fboolproperty->get_value_from_object((UEVR_FBoolPropertyHandle)fields[j], e) ? 1 : 0);
            }
            else if (!strcmp(t, "NameProperty")) { if (off + 8 <= size) fname_str((UEVR_FNameHandle)(e + off), v, sizeof(v)); }
            else if (!strcmp(t, "StrProperty")) {
                if (off + 16 <= size) {
                    wchar_t* s = *(wchar_t**)(e + off);
                    int32_t num = *(int32_t*)(e + off + 8);
                    if (s != NULL && num > 0 && num < 200 && readable(s, (size_t)num * 2)) {
                        int k;
                        WideCharToMultiByte(CP_UTF8, 0, s, num, v, sizeof(v) - 1, NULL, NULL);
                        v[sizeof(v) - 1] = 0;
                        for (k = 0; v[k]; k++) if (v[k] == '|' || v[k] == ';' || v[k] == '=' || v[k] == ',' || v[k] == '\n') v[k] = '_';
                    }
                }
            }
            else snprintf(v, sizeof(v), "~");
            if (j) app(out, cap, "|");
            app(out, cap, v);
        }
    }
    app(out, cap, "\n");
}

static void on_custom_event(const char* evt, const char* data) {
    static char out[16384];
    char cmd[16] = {0};
    unsigned long long gi = 0, sv = 0, sv2 = 0;
    if (evt == NULL || data == NULL || strcmp(evt, "sfinv") != 0) return;
    if (sscanf(data, "%15s %llx %llx %llx", cmd, &gi, &sv, &sv2) < 1 || strcmp(cmd, "read") != 0) return;
    out[0] = 0;
    if (sv) read_array((void*)(uintptr_t)sv, L"PlayerEquipment", "PlayerEquipment", out, sizeof(out));
    if (sv2 && sv2 != sv) read_array((void*)(uintptr_t)sv2, L"PlayerEquipment", "PlayerEquipment2", out, sizeof(out));
    if (gi) read_array((void*)(uintptr_t)gi, L"EquippedItems", "EquippedItems", out, sizeof(out));
    if (g_logged < 4) {
        char line[1100];
        const char* p = out;
        g_logged++;
        logi("[sf_inv] equipment read (read-only):");
        while (*p) {
            size_t n = strcspn(p, "\n");
            size_t k = n < 1000 ? n : 1000;
            memcpy(line, "[sf_inv] ", 9);
            memcpy(line + 9, p, k);
            line[9 + k] = 0;
            logi(line);
            p += n;
            if (*p == '\n') p++;
        }
    }
    if (P && P->functions && P->functions->dispatch_lua_event) P->functions->dispatch_lua_event("sfinv", out);
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
        SDK->farrayproperty == NULL || SDK->fstructproperty == NULL || SDK->uscriptstruct == NULL || SDK->fname == NULL ||
        SDK->ffield_class == NULL || SDK->uobject_hook == NULL) {
        logi("[sf_inv] not started: this UEVR build lacks part of the C API");
        return true;
    }
    if (param->callbacks != NULL && param->callbacks->on_custom_event != NULL) param->callbacks->on_custom_event(on_custom_event);
    logi("[sf_inv] loaded - reads the equipped-item lists for the Silverfish VR script (read-only, v2)");
    return true;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) { (void)inst; (void)reason; (void)reserved; return TRUE; }
